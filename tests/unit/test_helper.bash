#!/usr/bin/env bash

export REPO_ROOT
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

setup_test_env() {
  TEST_TMP="$(mktemp -d)"
  MOCK_BIN="$TEST_TMP/mock_bin"
  TEST_HOME="$TEST_TMP/home"
  TEST_WORKDIR="$TEST_TMP/work"
  MOCK_LOG="$TEST_TMP/mock.log"

  mkdir -p "$MOCK_BIN" "$TEST_HOME" "$TEST_WORKDIR"
  : >"$MOCK_LOG"

  export HOME="$TEST_HOME"
  export MOCK_BIN MOCK_LOG TEST_TMP TEST_HOME TEST_WORKDIR
  export ORIG_PATH="$PATH"
  export PATH="$MOCK_BIN:$PATH"
}

teardown_test_env() {
  if [[ -n "${ORIG_PATH:-}" ]]; then
    export PATH="$ORIG_PATH"
  fi
  if [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]]; then
    rm -rf "$TEST_TMP"
  fi
}

create_mock() {
  local name="$1"
  local body="$2"
  cat >"$MOCK_BIN/$name" <<EOF
#!/usr/bin/env bash
$body
EOF
  chmod +x "$MOCK_BIN/$name"
}

mock_uid() {
  local uid="$1"
  local username="${2:-testuser}"
  create_mock id "
if [[ \"\${1:-}\" == \"-u\" ]]; then
  echo \"$uid\"
  exit 0
elif [[ \"\${1:-}\" == \"-un\" ]]; then
  echo \"$username\"
  exit 0
fi
exit 1
"
}
