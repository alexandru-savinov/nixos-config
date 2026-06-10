# Validate n8n workflow JSON at flake-check time (#100).
#
# Workflows in n8n-workflows/ are imported by n8n-workflow-sync at service
# start; before this check, malformed JSON only failed at runtime, and a
# missing stable `id` caused duplicate workflows on every re-import.
{ pkgs }:
pkgs.runCommand "n8n-workflows-valid"
{
  nativeBuildInputs = [ pkgs.jq ];
  workflows = pkgs.lib.fileset.toSource {
    root = ../n8n-workflows;
    fileset = pkgs.lib.fileset.fileFilter (f: pkgs.lib.hasSuffix ".json" f.name) ../n8n-workflows;
  };
}
  ''
    fail=0
    cd "$workflows"
    for f in *.json; do
      echo "Validating: $f"
      if ! err=$(jq empty "$f" 2>&1); then
        echo "ERROR: invalid JSON in n8n-workflows/$f: $err"
        fail=1
        continue
      fi
      if ! jq -e '.id | type == "string" and length > 0' "$f" >/dev/null 2>&1; then
        echo "ERROR: n8n-workflows/$f has no non-empty string 'id' — required for idempotent re-import"
        fail=1
      fi
    done

    dupes=$(jq -r '.id // empty' *.json | sort | uniq -d)
    if [ -n "$dupes" ]; then
      echo "ERROR: duplicate workflow id(s) across n8n-workflows/: $dupes — re-import would clobber"
      fail=1
    fi

    if [ "$fail" -ne 0 ]; then
      echo "n8n-workflows-valid: FAILED"
      exit 1
    fi
    echo "n8n-workflows-valid: all $(ls *.json | wc -l) workflows OK"
    touch $out
  ''
