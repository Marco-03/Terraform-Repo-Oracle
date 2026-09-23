#!/usr/bin/env python3
"""Verify the static application payload and clean Resource Manager archive."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import zipfile


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--archive", type=Path)
    return parser.parse_args()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def assert_safe_infos(archive: zipfile.ZipFile, label: str) -> list[str]:
    names: list[str] = []
    seen: set[str] = set()
    casefolded: set[str] = set()

    bad_member = archive.testzip()
    if bad_member is not None:
        raise ValueError(f"{label} CRC/integrity failure at {bad_member}")

    for info in archive.infolist():
        name = info.filename
        path = PurePosixPath(name)
        if (
            not name
            or name.startswith("/")
            or "\\" in name
            or any(part in {"", ".", ".."} for part in path.parts)
        ):
            raise ValueError(f"{label} contains unsafe path: {name!r}")
        if name in seen:
            raise ValueError(f"{label} contains duplicate member: {name}")
        folded = name.casefold()
        if folded in casefolded:
            raise ValueError(f"{label} contains a case-colliding member: {name}")
        if info.flag_bits & 0x1:
            raise ValueError(f"{label} contains encrypted member: {name}")

        unix_mode = (info.external_attr >> 16) & 0xFFFF
        if stat.S_ISLNK(unix_mode):
            raise ValueError(f"{label} contains symbolic link: {name}")
        file_type = stat.S_IFMT(unix_mode)
        if file_type not in {0, stat.S_IFREG, stat.S_IFDIR}:
            raise ValueError(f"{label} contains special filesystem entry: {name}")

        seen.add(name)
        casefolded.add(folded)
        names.append(name)
    return names


def is_forbidden_member(name: str) -> bool:
    path = PurePosixPath(name.rstrip("/"))
    parts = [part.casefold() for part in path.parts]
    basename = parts[-1] if parts else ""

    forbidden_directories = {
        ".terraform",
        ".git",
        ".hg",
        ".svn",
        ".idea",
        ".vscode",
        "__macosx",
        "__pycache__",
        "node_modules",
        "coverage",
    }
    if any(part in forbidden_directories for part in parts):
        return True
    if (
        basename == ".ds_store"
        or (basename.startswith(".env") and basename != ".env.example")
        or basename.startswith("._")
    ):
        return True
    if basename.endswith(
        (
            ".pyc",
            ".pyo",
            ".swp",
            ".swo",
            ".log",
            ".pem",
            ".key",
            ".tfplan",
            ".tfvars",
            ".tfvars.json",
            ".tfstate",
            ".b64",
            ".p12",
            ".pfx",
            ".jks",
            "~",
        )
    ):
        return True
    if ".auto.tfvars" in basename or basename == "cwallet.sso":
        return True
    if ".tfstate." in basename or basename.endswith(".generated.zip"):
        return True
    if "wallet" in basename and basename.endswith(".zip"):
        return True
    return False


def scan_archive_text(
    archive: zipfile.ZipFile, names: list[str], label: str
) -> None:
    private_key = re.compile(
        rb"BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY"
    )
    local_model = re.compile(
        rb"\b(?:ollama|llama3[.]2|11434)\b", re.IGNORECASE
    )
    legacy_source_domain = re.compile(
        rb"\bfin" rb"ance\b|FIN" rb"ANCE_", re.IGNORECASE
    )

    for name in names:
        if (
            name.endswith("/")
            or name.casefold().endswith(".zip")
            or name.endswith("verification/check-resource-manager-package.py")
            or name.endswith("verification/check-selectai-platform-contract.sh")
        ):
            continue
        data = archive.read(name)
        if private_key.search(data):
            raise ValueError(f"{label} contains private-key material in {name}")
        if local_model.search(data):
            raise ValueError(
                f"{label} contains a forbidden local-model runtime reference in {name}"
            )
        if legacy_source_domain.search(data):
            raise ValueError(
                f"{label} contains a legacy source-domain reference in {name}"
            )


def validate_deployment_context_contract(
    graph_runtime: str,
    duality_runtime: str,
    handoff_final: str,
) -> None:
    refresh_marker = (
        "BEGIN\n  refresh_utilities_graph_domain;\nEND;"
    )
    refresh_invocation = graph_runtime.find(refresh_marker)
    validator_start = graph_runtime.find("\nDECLARE\n", refresh_invocation)
    validator_end = graph_runtime.find(
        "\n/\n\nCOMMIT;", validator_start
    )
    if (
        refresh_invocation < 0
        or validator_start < 0
        or validator_end < 0
    ):
        raise ValueError(
            "Application payload is missing the trailing graph validator"
        )
    validator = graph_runtime[validator_start:validator_end]

    required_validator_patterns = {
        "caller VPD identity snapshot": (
            r"v_caller_username\s+VARCHAR2\(128\)\s*:=\s*"
            r"SYS_CONTEXT\('UTILITIES_APP_CTX',\s*'USERNAME'\);"
        ),
        "caller VPD restore helper": r"PROCEDURE restore_caller_context IS",
        "temporary analyst identity": (
            r"utilities_security_pkg[.]set_user_context"
            r"\('analyst_raj'\);"
        ),
        "NULL caller clear branch": (
            r"IF v_caller_username IS NULL THEN\s+"
            r"utilities_security_pkg[.]clear_user_context;"
        ),
        "non-NULL caller restore branch": (
            r"ELSE\s+utilities_security_pkg[.]set_user_context"
            r"\(v_caller_username\);"
        ),
    }
    for label, pattern in required_validator_patterns.items():
        if not re.search(pattern, validator, re.DOTALL):
            raise ValueError(
                f"Application payload graph validator is missing {label}"
            )

    restore_calls = re.findall(
        r"^\s+restore_caller_context;\s*$", validator, re.MULTILINE
    )
    if len(restore_calls) != 2:
        raise ValueError(
            "Application payload graph validator must restore its caller "
            "on both success and failure"
        )
    if validator.count(
        "utilities_security_pkg.clear_user_context;"
    ) != 1:
        raise ValueError(
            "Application payload graph validator may clear context only "
            "inside the NULL-caller restore branch"
        )

    admin_call = (
        "utilities_security_pkg.set_user_context('admin_jess');"
    )
    first_admin = handoff_final.find(admin_call)
    graph_include = handoff_final.find(
        "@@../db/schema/13_utilities_graph_runtime.sql"
    )
    last_installer = handoff_final.find("@@../db/schema/09_comments.sql")
    acceptance_admin = handoff_final.find(admin_call, graph_include)
    exact_centers = handoff_final.find(
        "require_exact_rows('FULFILLMENT_CENTERS', 12);"
    )
    if not (
        0 <= first_admin < graph_include < last_installer
        < acceptance_admin < exact_centers
    ):
        raise ValueError(
            "Application payload FINAL handoff must reassert admin_jess "
            "after derived-runtime installers and before protected acceptance"
        )
    acceptance_guard = handoff_final[acceptance_admin:exact_centers]
    for attribute, expected in (
        ("AUTHENTICATED", "Y"),
        ("ACCESS_SCOPE", "GLOBAL"),
        ("ROLE", "admin"),
    ):
        pattern = (
            r"SYS_CONTEXT\('UTILITIES_APP_CTX',\s*'"
            + re.escape(attribute)
            + r"'\)\s*<>\s*'"
            + re.escape(expected)
            + r"'"
        )
        if not re.search(pattern, acceptance_guard):
            raise ValueError(
                "Application payload FINAL handoff is missing the "
                f"{attribute} VPD acceptance guard"
            )

    for name in (
        "utilities_work_order_documents_dv",
        "products_inventory_dv",
        "manufactured_part_capacity_dv",
        "utilities_plant_capacity_dv",
    ):
        view_compile = duality_runtime.find(
            f"ALTER VIEW {name} COMPILE;"
        )
        synonym_compile = duality_runtime.find(
            f'ALTER SYNONYM "{name}" COMPILE;'
        )
        if not (
            0 <= view_compile < synonym_compile
        ):
            raise ValueError(
                "Application payload duality revalidation must compile "
                f"the lowercase {name} collection synonym after its target"
            )


def validate_native_sql_tool_contract(native_bootstrap: str) -> None:
    registration_patterns = {
        "SQL tool type": r"'tool_type'\s+VALUE\s+'SQL'",
        "Select AI profile binding": (
            r"'profile_name'\s+VALUE\s+'UTILITIES_SELECTAI_V1'"
        ),
        "Utilities SQL tool registration": (
            r"DBMS_CLOUD_AI_AGENT[.]CREATE_TOOL\(\s*"
            r"tool_name\s*=>\s*'UTILITIES_READONLY_SQL_TOOL'"
        ),
    }
    for label, pattern in registration_patterns.items():
        if not re.search(pattern, native_bootstrap, re.DOTALL):
            raise ValueError(
                f"Application payload native bootstrap is missing {label}"
            )

    probe_start = native_bootstrap.find(
        "l_agent_tool := DBMS_CLOUD_AI_AGENT.RUN_TOOL("
    )
    probe_end = native_bootstrap.find(
        "DBMS_OUTPUT.PUT_LINE('UTILITIES_NATIVE_AI_AGENT_TOOL_OK');",
        probe_start,
    )
    if probe_start < 0 or probe_end < 0:
        raise ValueError(
            "Application payload is missing the native SQL RUN_TOOL probe"
        )
    probe = native_bootstrap[probe_start:probe_end]
    input_end = probe.find("\n  );")
    if input_end < 0:
        raise ValueError(
            "Application payload native SQL RUN_TOOL call is malformed"
        )
    probe_input = probe[:input_end]

    required_probe_patterns = {
        "Utilities SQL tool name": (
            r"tool_name\s*=>\s*'UTILITIES_READONLY_SQL_TOOL'"
        ),
        "execution-derived row marker query": (
            r"SELECT ''UTILITIES_SQL_TOOL_ROWS_''\s*[|][|].*"
            r"TO_CHAR\(COUNT\(\*\),\s*''FM9999999990''\).*"
            r"FROM UTILITIES_PARTS_V"
        ),
        "RUNSQL action": r'"ACTION":"RUNSQL"',
        "non-NULL result guard": r"l_agent_tool IS NULL",
        "non-empty result guard": (
            r"DBMS_LOB[.]GETLENGTH\(l_agent_tool\)\s*=\s*0"
        ),
        "whole-CLOB execution marker": (
            r"DBMS_LOB[.]INSTR\(\s*UPPER\(l_agent_tool\),\s*"
            r"'UTILITIES_SQL_TOOL_ROWS_31',\s*1,\s*1\s*\)\s*=\s*0"
        ),
    }
    for label, pattern in required_probe_patterns.items():
        target = (
            probe_input
            if label in {
                "Utilities SQL tool name",
                "execution-derived row marker query",
                "RUNSQL action",
            }
            else probe
        )
        if not re.search(pattern, target, re.DOTALL):
            raise ValueError(
                "Application payload native SQL tool probe is missing "
                f"{label}"
            )

    if "UTILITIES_SQL_TOOL_ROWS_31" in probe_input:
        raise ValueError(
            "Application payload native SQL tool input contains its expected "
            "execution result and can false-pass by echoing"
        )
    if "TOTAL_ROWS" in probe:
        raise ValueError(
            "Application payload native SQL tool probe still relies on a "
            "display alias"
        )
    if re.search(
        r"DBMS_LOB[.]SUBSTR\(\s*l_agent_tool", probe, re.IGNORECASE
    ):
        raise ValueError(
            "Application payload native SQL tool probe truncates its result"
        )


def validate_admin_password_transport_contract(adb_bootstrap: str) -> None:
    """Require secret-free drivers and SQLcl startup password input."""

    if re.search(r"(?mi)^[ \t]*CONNECT[ \t]+ADMIN\b", adb_bootstrap):
        raise ValueError(
            "Application payload must not place an ADMIN login in a SQL "
            "driver; SQLcl startup must own the password prompt"
        )
    if re.search(
        r"(?m)^[ \t]*\$\{ADB_ADMIN_PASSWORD\}[ \t]*$", adb_bootstrap
    ):
        raise ValueError(
            "Application payload must not write the ADMIN password into a "
            "SQL driver"
        )

    required_transport_patterns = {
        "connection-mode argument": (
            r'local[ \t]+connection_mode="\$\{5:-nolog\}"'
        ),
        "password first on stdin": (
            r"printf[ \t]+'%s\\n'[ \t]+\"\$\{ADB_ADMIN_PASSWORD\}\""
        ),
        "driver after password": r'cat[ \t]+\"\$\{driver\}\"',
        "secret-free SQLcl startup logon": (
            r'sql[ \t]+-S[ \t]+-L[ \t]+-cloudconfig[ \t]+'
            r'\"\$\{WALLET_ARCHIVE\}\"[ \t]+'
            r'(?:\\[ \t]*\r?\n[ \t]*)?'
            r'\"ADMIN@\$\{ADB_CONNECT_STRING\}\"'
        ),
    }
    for label, pattern in required_transport_patterns.items():
        if not re.search(pattern, adb_bootstrap):
            raise ValueError(
                "Application payload ADB bootstrap is missing " + label
            )

    password_pipe = re.search(
        r"\{[ \t\r\n]*"
        r"printf[ \t]+'%s\\n'[ \t]+\"\$\{ADB_ADMIN_PASSWORD\}\""
        r"[ \t\r\n]+cat[ \t]+\"\$\{driver\}\"[ \t\r\n]*"
        r"\}[ \t]*\|[ \t\r\n]*"
        r"sql[ \t]+-S[ \t]+-L[ \t]+-cloudconfig[ \t]+"
        r'\"\$\{WALLET_ARCHIVE\}\"[ \t]+'
        r'(?:\\[ \t]*\r?\n[ \t]*)?'
        r'\"ADMIN@\$\{ADB_CONNECT_STRING\}\"',
        adb_bootstrap,
    )
    if not password_pipe:
        raise ValueError(
            "Application payload must pipe the ADMIN password before the "
            "secret-free SQL driver into SQLcl startup logon"
        )

    admin_phases = re.findall(
        r'run_sql_phase[ \t]+\"([^\"]+)\"[ \t]+\"[^\"]+\"'
        r'[ \t]+\\[ \t]*\r?\n[ \t]*\"[^\"]+\"[ \t]+'
        r'\"none\"[ \t]+\"admin_password_stdin\"[ \t]*$',
        adb_bootstrap,
        re.MULTILINE,
    )
    if admin_phases != ["bootstrap", "security"]:
        raise ValueError(
            "Application payload must bind startup password input only to "
            "the bootstrap and security ADMIN phases"
        )

    if re.search(
        r"(?mi)^(?:[^\r\n]*\b(?:sql|connect)\b[^\r\n]*)"
        r"\$\{ADB_ADMIN_PASSWORD\}",
        adb_bootstrap,
    ):
        raise ValueError(
            "Application payload must not expose the ADMIN password in a "
            "SQLcl command or CONNECT statement"
        )


def validate_payload(payload_path: Path) -> tuple[str, int]:
    if not payload_path.is_file():
        raise ValueError(f"Static application payload is missing: {payload_path}")

    with zipfile.ZipFile(payload_path) as archive:
        names = assert_safe_infos(archive, "application payload")
        forbidden = [name for name in names if is_forbidden_member(name)]
        if forbidden:
            raise ValueError(
                "Application payload contains forbidden artifact: " + forbidden[0]
            )
        nested = [
            name
            for name in names
            if not name.endswith("/") and name.casefold().endswith(".zip")
        ]
        if nested:
            raise ValueError(
                "Application payload contains an unexpected nested ZIP: " + nested[0]
            )
        required = {
            "Containerfile",
            "package.json",
            "package-lock.json",
            "frontend/package.json",
            "deployment/bootstrap-utilities-adb.sh",
            "backend/lib/nativeSelectAi.js",
        }
        missing = sorted(required.difference(names))
        if missing:
            raise ValueError(
                "Application payload is missing required root member(s): "
                + ", ".join(missing)
            )
        if any(name.startswith("application/") for name in names):
            raise ValueError(
                "Application payload must be rootless; found application/ prefix"
            )
        if not any(name.startswith("verification/demo-dataset/") for name in names):
            raise ValueError(
                "Application payload is missing the runtime demo-dataset bundle"
            )
        scan_archive_text(archive, names, "application payload")
        handoff = archive.read("deployment/bootstrap-utilities-adb.sh").decode("utf-8")
        if "UTILITIES_SELECTAI_V1" not in handoff or "UTIL_GENAI_KEY_V1" not in handoff:
            raise ValueError("Utilities handoff is missing its managed native Select AI contract")
        for role in (
            "SC_ADMIN",
            "SC_ANALYST",
            "SC_FULFILLMENT_MGR",
            "SC_FIELD_SUPERVISOR",
            "SC_VIEWER",
        ):
            if f"ensure_role('{role}')" not in handoff:
                raise ValueError(
                    "Utilities ADMIN bootstrap must create semantic-view role " + role
                )
        if "context_admin_sql=\"${WORK_DIR}/06a_utilities_app_context_admin.sql\"" not in handoff or "sed -E '/^[[:space:]]*EXIT[[:space:]]+SUCCESS[[:space:]]*$/Id'" not in handoff:
            raise ValueError(
                "Utilities nested ADMIN context script must remove its standalone EXIT"
            )

        audit_admin = archive.read(
            "db/schema/16_utilities_unified_audit_admin.sql"
        ).decode("utf-8")
        tables = archive.read("db/schema/01_tables.sql").decode("utf-8")
        demo_route = archive.read("backend/routes/demo.js").decode("utf-8")
        if "GRANT SELECT ON SYS.AUDIT_UNIFIED_ENABLED_POLICIES" in audit_admin:
            raise ValueError(
                "Utilities audit bootstrap must not delegate SYS audit-catalog access"
            )
        audit_required = {
            "schema-owned audit evidence table": "CREATE TABLE utilities_audit_evidence",
            "ADMIN evidence writer grant": (
                "GRANT INSERT, UPDATE ON utilities_audit_evidence TO ADMIN"
            ),
            "verified audit evidence merge": (
                "MERGE INTO &&APP_SCHEMA_OWNER..utilities_audit_evidence"
            ),
            "catalog-source verification": "FROM audit_unified_enabled_policies",
            "least-privilege audit readiness route": (
                "FROM utilities_audit_evidence"
            ),
            "runtime evidence source": "source: 'UTILITIES_AUDIT_EVIDENCE'",
        }
        audit_targets = {
            "schema-owned audit evidence table": tables,
            "ADMIN evidence writer grant": tables,
            "verified audit evidence merge": audit_admin,
            "catalog-source verification": audit_admin,
            "least-privilege audit readiness route": demo_route,
            "runtime evidence source": demo_route,
        }
        for label, token in audit_required.items():
            if token not in audit_targets[label]:
                raise ValueError("Utilities audit readiness is missing " + label)

        vector_finalizer = archive.read(
            "db/data/finalize_vector_search.sql"
        ).decode("utf-8")
        vector_required = {
            "cross-schema model grant": (
                "GRANT SELECT ON MINING MODEL ADMIN.ALL_MINILM_L12_V2 TO APP_USER"
            ),
            "owner-aware finalizer catalog": "FROM all_mining_models",
            "ADMIN model-owner predicate": "WHERE owner = 'ADMIN'",
            "qualified vector embedding model": "ADMIN.ALL_MINILM_L12_V2",
        }
        vector_targets = {
            "cross-schema model grant": handoff,
            "owner-aware finalizer catalog": vector_finalizer,
            "ADMIN model-owner predicate": vector_finalizer,
            "qualified vector embedding model": vector_finalizer,
        }
        for label, token in vector_required.items():
            if token not in vector_targets[label]:
                raise ValueError("Utilities vector finalizer is missing " + label)
        if "FROM user_mining_models" in vector_finalizer:
            raise ValueError(
                "Utilities vector finalizer must not use APP_USER-scoped model catalog"
            )

        runtime_vector = archive.read(
            "backend/lib/importWorkflowService.js"
        ).decode("utf-8")
        social_route = archive.read("backend/routes/social.js").decode("utf-8")
        runtime_vector_required = {
            "qualified runtime model constant": (
                "const VECTOR_MODEL_SQL = 'ADMIN.ALL_MINILM_L12_V2'"
            ),
            "runtime model catalog": "FROM all_mining_models",
            "runtime ADMIN owner bind": "WHERE owner = :modelOwner",
            "qualified runtime embedding": "VECTOR_EMBEDDING(${VECTOR_MODEL_SQL} USING",
        }
        for label, token in runtime_vector_required.items():
            if token not in runtime_vector:
                raise ValueError("Utilities runtime vector contract is missing " + label)
        availability_start = runtime_vector.find("async function isVectorModelAvailable")
        availability_end = runtime_vector.find("async function regenerateVectorArtifacts", availability_start)
        if (
            availability_start < 0
            or availability_end < 0
            or "user_mining_models" in runtime_vector[availability_start:availability_end]
        ):
            raise ValueError(
                "Utilities runtime shared-model availability proof must not use "
                "APP_USER-scoped model catalog"
            )
        if social_route.count("VECTOR_EMBEDDING(ADMIN.ALL_MINILM_L12_V2 USING") != 4:
            raise ValueError(
                "Utilities semantic-search route must owner-qualify every embedding call"
            )

        native_ai = archive.read("backend/lib/nativeSelectAi.js").decode("utf-8")
        native_routes = archive.read("backend/routes/selectai.js").decode("utf-8")
        native_required = {
            "OCI GenAI package invocation": "DBMS_CLOUD_AI.GENERATE",
            "governed SQL generation": (
                "generateText(\n"
                "    connection,\n"
                "    'showsql',"
            ),
            "grounded OCI GenAI explanation": "generateText(connection, 'chat'",
            "actor-scoped native call": "db.withActorConnection(actor",
            "curated Utilities object allowlist": "const ALLOWED_OBJECTS = new Set([",
            "governed request-item relationship": "'UTILITY_REQUEST_ITEMS'",
            "service-to-request relationship guidance": "GOVERNED_RELATIONSHIP_GUIDANCE",
            "invalid service-point join rejection": "joined unrelated utility-service and service-point identifiers",
            "feeder outage-risk intent guard": "validateQuestionSemanticContract",
            "electric-feeder category guard": "'ELECTRIC UTILITY'",
            "native agent team execution": "DBMS_CLOUD_AI_AGENT.RUN_TEAM",
            "governed agent implementation": "async function runAgentTeam",
            "agent evidence grounding": "VPD-filtered database evidence",
            "refinery evidence guidance": "RFY-HCU-02 refinery throughput constraints",
            "operational-event evidence allowlist": "'OPERATIONAL_EVENT_EVIDENCE_V'",
            "gas leak event intent guard": "isGasLeakResponseQuestion",
            "gas leak event retry prompt": "Summarize gas leak response event GLK-2208",
            "native agent audit proposal": "recordAgentProposal",
            "strict generated-SQL validation": "SQL_VALIDATION_BLOCKED",
            "quoted APP_USER view normalization": "replace(/\"/g, '')",
            "no native fallback": "NATIVE_AI_UNAVAILABLE",
        }
        for label, token in native_required.items():
            if token not in native_ai:
                raise ValueError("Utilities native AI runtime is missing " + label)
        if "JSON_OBJECT('owner' VALUE USER, 'name' VALUE 'UTILITY_REQUEST_ITEMS')" not in handoff:
            raise ValueError(
                "Utilities native AI profile must expose its governed request-item relationship view"
            )
        if "JSON_OBJECT('owner' VALUE USER, 'name' VALUE 'OPERATIONAL_EVENT_EVIDENCE_V')" not in handoff:
            raise ValueError(
                "Utilities native AI profile must expose its governed operational-event evidence view"
            )
        if "'comments' VALUE true" not in handoff:
            raise ValueError(
                "Utilities native AI profile must expose governed semantic comments"
            )
        if "Answer the Utilities request directly from supplied governed evidence" not in handoff:
            raise ValueError(
                "Utilities service-request task must require a direct evidence-led answer"
            )
        if (
            '"agents":[{"name":"UTILITY_SERVICE_REQUEST_AGENT","task":"UTILITY_SERVICE_REQUEST_TASK"},'
            '{"name":"UTILITIES_OPERATIONS_SUPERVISOR"}]' in handoff
        ):
            raise ValueError(
                "Utilities service-request team must not include the clarification-only supervisor"
            )
        route_required = {
            "profile metadata route": "router.get('/profiles'",
            "schema metadata route": "router.get('/schema-objects'",
            "separate Explain route": "router.post('/chat'",
            "separate Chat route": "router.post('/chat-mode'",
            "separate Show SQL route": "router.post('/showsql'",
            "separate Run SQL route": "router.post('/runsql'",
            "OCI GenAI response evidence": "provider: 'OCI Generative AI'",
        }
        for label, token in route_required.items():
            if token not in native_routes:
                raise ValueError("Utilities native AI route contract is missing " + label)

        agent_route = archive.read("backend/routes/agents.js").decode("utf-8")
        if "router.get('/actions'" not in agent_route or "FROM agent_actions" not in agent_route:
            raise ValueError("Utilities agent console must expose persisted action history")

        oml_required = {
            "OML model-creation privilege": "CREATE MINING MODEL",
            "OML package execute grant": "GRANT EXECUTE ON SYS.DBMS_DATA_MINING TO APP_USER",
            "persisted OML model rebuild": "rebuild_utilities_oml_models",
        }
        oml_sql = archive.read("db/schema/12_oml_models.sql").decode("utf-8")
        oml_targets = {
            "OML model-creation privilege": handoff,
            "OML package execute grant": handoff,
            "persisted OML model rebuild": oml_sql,
        }
        for label, token in oml_required.items():
            if token not in oml_targets[label]:
                raise ValueError("Utilities OML bootstrap is missing " + label)

        agent_status_required = {
            "native credential checkpoint": "PROMPT UTILITIES_SQL_STEP=native_credential",
            "native profile checkpoint": "PROMPT UTILITIES_SQL_STEP=native_profile",
            "native agents checkpoint": "PROMPT UTILITIES_SQL_STEP=native_agents",
            "native tasks checkpoint": "PROMPT UTILITIES_SQL_STEP=native_tasks",
            "native teams checkpoint": "PROMPT UTILITIES_SQL_STEP=native_teams",
            "grid agent enabled status": (
                "'ENABLED', 'Utilities grid reliability advisor'"
            ),
            "field agent enabled status": (
                "'ENABLED', 'Utilities field logistics advisor'"
            ),
            "service agent enabled status": (
                "'ENABLED', 'Utilities service request advisor'"
            ),
            "tool-free task enabled status": (
                "'ENABLED', 'Tool-free reliability task'"
            ),
            "team enabled status": "'ENABLED', 'Tool-free reliability team'",
        }
        for label, token in agent_status_required.items():
            if token not in handoff:
                raise ValueError("Utilities native-agent bootstrap is missing " + label)
        if handoff.find("PROMPT UTILITIES_SQL_STEP=native_credential") > handoff.find(
            "PROMPT UTILITIES_SQL_STEP=native_profile"
        ) or handoff.find("PROMPT UTILITIES_SQL_STEP=native_profile") > handoff.find(
            "PROMPT UTILITIES_SQL_STEP=native_agents"
        ) or handoff.find("PROMPT UTILITIES_SQL_STEP=native_agents") > handoff.find(
            "PROMPT UTILITIES_SQL_STEP=native_tasks"
        ) or handoff.find("PROMPT UTILITIES_SQL_STEP=native_tasks") > handoff.find(
            "PROMPT UTILITIES_SQL_STEP=native_teams"
        ):
            raise ValueError(
                "Utilities native-agent bootstrap checkpoints must be ordered"
            )

        return sha256_file(payload_path), sum(
            not name.endswith("/") for name in names
        )


def load_build_contract(source_root: Path):
    scripts_dir = source_root / "scripts"
    sys.path.insert(0, str(scripts_dir))
    try:
        import build_resource_manager_package as build_contract
        import create_clean_zip as clean_zip
    finally:
        sys.path.pop(0)
    return build_contract, clean_zip


def expected_entries(
    source: Path,
    output: Path,
    excludes: tuple[str, ...],
    clean_zip,
) -> tuple[dict[str, Path], set[str]]:
    namespace = argparse.Namespace(
        contents_only=True,
        root_name=None,
        exclude=list(excludes),
        no_default_excludes=False,
        reproducible=True,
    )
    entries, skipped = clean_zip.collect_paths(source, output, namespace)
    if any(item.startswith("symlink ") for item in skipped):
        raise ValueError("Source parity encountered a skipped symlink")
    files = {name: path for path, name, is_dir in entries if not is_dir}
    all_names = {name for _, name, _ in entries}
    return files, all_names


def assert_source_parity(
    archive_path: Path,
    source: Path,
    output: Path,
    excludes: tuple[str, ...],
    clean_zip,
    label: str,
) -> None:
    expected_files, expected_names = expected_entries(
        source, output, excludes, clean_zip
    )
    with zipfile.ZipFile(archive_path) as archive:
        actual_names = set(archive.namelist())
        if actual_names != expected_names:
            missing = sorted(expected_names - actual_names)
            extra = sorted(actual_names - expected_names)
            raise ValueError(
                f"{label} source parity mismatch; missing={missing[:3]}, "
                f"extra={extra[:3]}"
            )
        for name, path in expected_files.items():
            actual_hash = sha256_bytes(archive.read(name))
            expected_hash = sha256_file(path)
            if actual_hash != expected_hash:
                raise ValueError(f"{label} content drift at {name}")


def validate_terraform_static_contract(source_root: Path) -> None:
    terraform_text = "\n".join(
        path.read_text(encoding="utf-8")
        for path in sorted(source_root.glob("*.tf"))
    )
    required_patterns = {
        "static payload path": r"payload/utilities-application[.]zip",
        "Utilities Select AI profile": r'UTILITIES_SELECTAI_V1',
        "Utilities agent teams": r'UTILITIES_OPERATIONS_TEAM,OUTAGE_RESTORATION_TEAM,FIELD_OPERATIONS_TEAM',
        "plan-time payload hash": r"filesha256[(]local[.]application_payload_path[)]",
        "direct object source": r"source\s*=\s*local[.]application_payload_path",
        "hash-addressed object": r"local[.]application_payload_sha256",
        "digest-keyed payload resource": r"for_each\s*=\s*toset[(]\[local[.]application_payload_sha256\]\)",
        "immutable payload object path": r'object\s*=\s*"application/payloads/\$\{each[.]key\}[.]zip"',
        "digest-keyed payload reference": r"oci_objectstorage_object[.]application\[local[.]application_payload_sha256\][.]object",
        "Utilities bootstrap callback format": r"utilities-rm-bootstrap/v1",
        "Utilities public-key callback format": r"utilities-selectai-api-key-public/v1",
        "Utilities activation callback format": r"utilities-selectai-api-key-activation/v1",
        "gzip cloud-init": r"base64gzip[(]local[.]application_cloud_init[)]",
        "metadata budget": r"application_instance_metadata_budget_bytes\s*=\s*30000",
        "metadata precondition": r"application_metadata_size_bytes\s*<=\s*local[.]application_instance_metadata_budget_bytes",
        "Compute delivery trigger": r'filesha256[(]"\$\{path[.]module\}/compute-app[.]tf"[)]',
        "Object Storage delivery trigger": r'filesha256[(]"\$\{path[.]module\}/object-storage[.]tf"[)]',
        "identity-domain input": r'variable\s+"identity_domain_ocid"',
        "validated OCI provider": r'version\s*=\s*"=\s*8[.]25[.]0"',
        "validated Random provider": r'version\s*=\s*"=\s*3[.]9[.]0"',
        "identity-domain lookup": r'data\s+"oci_identity_domain"\s+"selected"',
        "self-service key inventory": r'data\s+"oci_identity_domains_my_api_keys"\s+"current"',
        "self-service API-key resource": r'resource\s+"oci_identity_domains_my_api_key"\s+"select_ai"',
        "Identity Domains API-key schema": r"urn:ietf:params:scim:schemas:oracle:idcs:apikey",
        "API-key capacity guard": r"total_results\s*<\s*3",
        "Plan-known key owner token": r"selectai_api_key_owner_token\s*=\s*substr[(]sha256[(]jsonencode",
        "current-user binding": r"self[.]user\[0\][.]ocid\s*==\s*var[.]current_user_ocid",
        "identity-domain binding": r"self[.]domain_ocid\s*==\s*var[.]identity_domain_ocid",
    }
    for label, pattern in required_patterns.items():
        if not re.search(pattern, terraform_text):
            raise ValueError(f"Terraform is missing {label}")
    if re.search(r"\b(?:data|resource)\s+\"archive_file\"", terraform_text):
        raise ValueError("Terraform still creates the application ZIP at job time")
    if "hashicorp/archive" in terraform_text:
        raise ValueError("Terraform still declares the archive provider")
    if re.search(r"base64encode\s*[(]\s*templatefile\s*[(]", terraform_text):
        raise ValueError("Terraform still ships plain-Base64 cloud-init")
    if re.search(r'resource\s+"oci_identity_api_key"', terraform_text):
        raise ValueError("Terraform still uses the legacy IAM API-key resource")
    if re.search(
        r"selectai_api_key_description\s*=.*random_id", terraform_text
    ):
        raise ValueError(
            "Terraform defers the API-key capacity decision past Plan"
        )


def validate_vm_bootstrap_prerequisites(source_root: Path) -> None:
    bootstrap = (source_root / "scripts" / "bootstrap_app_vm.sh").read_text(
        encoding="utf-8"
    )
    required = {
        "OL9 Java 17 runtime": "java-17-openjdk-headless",
        "pinned SQLcl source": (
            "https://download.oracle.com/otn_software/java/sqldeveloper/"
            "sqlcl-26.2.2.233.1901.zip"
        ),
        "pinned SQLcl digest": (
            "17f89fddf69722f37d7bde0718e66490647b25b295bf52fba92ba0ad042fa256"
        ),
        "SQLcl digest gate": "sha256sum --check --status",
        "SQLcl command installation": "ln -sfn \"${sqlcl_binary}\" /usr/local/bin/sql",
        "SQL-step callback propagation": "last_bootstrap_error_step",
        "proxy-free local health check": "curl --noproxy '*' -fsS",
    }
    for label, token in required.items():
        if token not in bootstrap:
            raise ValueError(f"VM bootstrap is missing {label}")
    if re.search(r"dnf_install_with_retry\s+[^\n]*\b(sqlcl|jdk-21-headless)\b", bootstrap):
        raise ValueError(
            "VM bootstrap retries unavailable OL9 sqlcl or jdk-21-headless RPMs"
        )


def validate_outer_archive(
    archive_path: Path, payload_path: Path
) -> tuple[str, int]:
    with zipfile.ZipFile(archive_path) as archive:
        names = assert_safe_infos(archive, "Resource Manager archive")
        forbidden = [name for name in names if is_forbidden_member(name)]
        if forbidden:
            raise ValueError(
                "Resource Manager archive contains forbidden artifact: "
                + forbidden[0]
            )
        required = {
            "main.tf",
            "schema.yaml",
            "payload/utilities-application.zip",
            "verification/check-compute-metadata-budget.py",
            "verification/utilities-livestack-regression.mjs",
        }
        missing = sorted(required.difference(names))
        if missing:
            raise ValueError(
                "Resource Manager archive is missing root contract member(s): "
                + ", ".join(missing)
            )
        if any(name.startswith("application/") for name in names):
            raise ValueError(
                "Resource Manager archive contains duplicate raw application source"
            )
        nested = [
            name
            for name in names
            if not name.endswith("/") and name.casefold().endswith(".zip")
        ]
        if nested != ["payload/utilities-application.zip"]:
            raise ValueError(
                "Resource Manager archive must contain exactly one approved "
                f"nested ZIP; found {nested}"
            )
        embedded_hash = sha256_bytes(
            archive.read("payload/utilities-application.zip")
        )
        if embedded_hash != sha256_file(payload_path):
            raise ValueError(
                "Embedded application payload differs from the verified source payload"
            )
        scan_archive_text(archive, names, "Resource Manager archive")
        return sha256_file(archive_path), sum(
            not name.endswith("/") for name in names
        )


def main() -> int:
    args = parse_args()
    source_root = args.source_root.expanduser().resolve()
    payload_path = source_root / "payload" / "utilities-application.zip"

    validate_terraform_static_contract(source_root)
    validate_vm_bootstrap_prerequisites(source_root)
    payload_hash, payload_files = validate_payload(payload_path)

    application_root = source_root / "application"
    if application_root.is_dir():
        build_contract, clean_zip = load_build_contract(source_root)
        assert_source_parity(
            payload_path,
            application_root,
            payload_path,
            build_contract.PAYLOAD_EXCLUDES,
            clean_zip,
            "application payload",
        )
        print("PASS: application payload exactly matches clean source allowlist")
    else:
        print(
            "INFO: raw application source is intentionally absent; "
            "payload source-parity check skipped"
        )

    print(
        f"PASS: static application payload is clean "
        f"({payload_files} files, sha256={payload_hash})"
    )

    if args.archive:
        archive_path = args.archive.expanduser().resolve()
        archive_hash, archive_files = validate_outer_archive(
            archive_path, payload_path
        )
        if application_root.is_dir():
            build_contract, clean_zip = load_build_contract(source_root)
            assert_source_parity(
                archive_path,
                source_root,
                archive_path,
                build_contract.OUTER_EXCLUDES,
                clean_zip,
                "Resource Manager archive",
            )
            print(
                "PASS: Resource Manager archive exactly matches clean source allowlist"
            )
        print(
            f"PASS: Resource Manager archive is clean "
            f"({archive_files} files, sha256={archive_hash})"
        )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, zipfile.BadZipFile) as exc:
        print(f"package verification failed: {exc}", file=sys.stderr)
        raise SystemExit(2)
