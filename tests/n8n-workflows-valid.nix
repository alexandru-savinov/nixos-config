# Validate n8n workflow JSON at flake-check time (#100).
#
# Workflows in n8n-workflows/ are imported by n8n-workflow-sync at service
# start; before this check, malformed JSON only failed at runtime, and a
# missing stable `id` caused duplicate workflows on every re-import.
#
# Subdirectories are validated too: n8n-workflows/choir/ is sancta-choir's
# own set (sq085), imported there via its own workflowsDir. The sync unit
# globs <dir>/*.json non-recursively, so rpi5-full never imports it. Ids must
# be unique across ALL sets, so a workflow can never collide when moved.
{ pkgs }:
pkgs.runCommand "n8n-workflows-valid"
{
  nativeBuildInputs = [ pkgs.jq pkgs.findutils ];
  workflows = pkgs.lib.fileset.toSource {
    root = ../n8n-workflows;
    fileset = pkgs.lib.fileset.fileFilter (f: pkgs.lib.hasSuffix ".json" f.name) ../n8n-workflows;
  };
}
  ''
    fail=0
    cd "$workflows"
    mapfile -t files < <(find . -type f -name '*.json' -printf '%P\n' | sort)
    if [ "''${#files[@]}" -eq 0 ]; then
      echo "ERROR: no workflow JSON found under n8n-workflows/"
      exit 1
    fi
    for f in "''${files[@]}"; do
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

    dupes=$(jq -r '.id // empty' "''${files[@]}" 2>/dev/null | sort | uniq -d)
    if [ -n "$dupes" ]; then
      echo "ERROR: duplicate workflow id(s) across n8n-workflows/: $dupes — re-import would clobber"
      fail=1
    fi

    if [ "$fail" -ne 0 ]; then
      echo "n8n-workflows-valid: FAILED"
      exit 1
    fi
    echo "n8n-workflows-valid: all ''${#files[@]} workflows OK"
    touch $out
  ''
