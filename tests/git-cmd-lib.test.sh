#!/usr/bin/env bash
# Regression tests for hooks/git-cmd-lib.sh — the shared git command tokenizer.
#
# Every case here is a command form the gates' old detection got wrong. The
# literal substring `*"git commit"*` they fell back to matched no git-level
# option and not even a double space, while matching the same words inside a
# quoted string. Both directions are asserted: forms that MUST be seen, and
# data that must NOT be mistaken for a command.
# Run: bash git-cmd-lib.test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=hooks/git-cmd-lib.sh
. "$SCRIPT_DIR/../hooks/git-cmd-lib.sh"

pass=0
fail=0

check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "PASS: $1"
    pass=$((pass + 1))
  else
    echo "FAIL: $1 — expected '$2', got '$3'"
    fail=$((fail + 1))
  fi
}

count() { # count <name> <subcommand> <expected-n> <command>
  git_cmd_scan "$2" "$4"
  check "$1" "$3" "$GIT_CMD_N"
}

# --- forms that bypassed the literal substring -------------------------------
count "plain commit detected"              commit 1 'git commit -m "feat: x"'
count "--no-pager commit detected"         commit 1 'git --no-pager commit -m "feat: x"'
count "double space commit detected"       commit 1 'git  commit -m "feat: x"'
count "tab before commit detected"         commit 1 'git	commit -m "feat: x"'
count "-c config commit detected"          commit 1 'git -c user.name=x commit -m "feat: x"'
count "--git-dir commit detected"          commit 1 'git --git-dir=/tmp/r/.git commit -m "feat: x"'
count "-C path commit detected"            commit 1 'git -C /tmp/r commit -m "feat: x"'
count "--paginate push detected"           push   1 'git --paginate push origin main'
count "--no-pager push detected"           push   1 'git --no-pager push origin main'
count "--git-dir + --work-tree push"       push   1 'git --git-dir=.git --work-tree=. push origin main'
count "sudo git push detected"             push   1 'sudo git push origin main'
count "env-prefixed push detected"         push   1 'GIT_TRACE=1 git push origin main'

# --- data that must NOT be read as a command ---------------------------------
count "quoted commit in grep pattern"      commit 0 "grep -n 'git commit' hooks/x.sh"
count "commit words inside a message"      commit 0 'echo "remember to git commit later"'
count "push words inside a message"        push   0 'git commit -m "then run git push origin main"'
count "separator inside quotes not split"  push   0 'git commit -m "a; git push origin main"'
count "unrelated subcommand"               commit 0 'git status --short'
count "push is not commit"                 commit 0 'git push origin main'
count "commit is not push"                 push   0 'git commit -m "feat: x"'
count "filename containing push"           push   0 'cat hooks/pre-push-gate.sh'

# --- every invocation, not just the first ------------------------------------
count "two pushes joined by &&"            push   2 'git push -u origin main && git push origin feature-a'
count "two pushes on separate lines"       push   2 'git push origin feature-a
git push origin main'
count "two pushes joined by ;"             push   2 'git push origin a; git push origin b'
count "two pushes joined by ||"            push   2 'git push origin a || git push origin b'
count "commit then push counted once each" push   1 'git commit -m "feat: x" && git push origin main'
count "backslash continuation is one push" push   1 'git push \
  origin main'

# --- -C / --git-dir path extraction ------------------------------------------
git_cmd_scan commit 'git -C /tmp/repo commit -m "feat: x"'
check "bare -C path extracted" "/tmp/repo" "${GIT_CMD_CPATH[0]}"

git_cmd_scan commit 'git -C "/tmp/my repo" commit -m "feat: x"'
check "quoted -C path keeps its space" "/tmp/my repo" "${GIT_CMD_CPATH[0]}"

git_cmd_scan commit "git -C '/tmp/my repo' commit -m 'feat: x'"
check "single-quoted -C path keeps its space" "/tmp/my repo" "${GIT_CMD_CPATH[0]}"

git_cmd_scan commit 'git --git-dir=/tmp/repo/.git commit -m "feat: x"'
check "--git-dir= path extracted" "/tmp/repo/.git" "${GIT_CMD_CPATH[0]}"

git_cmd_scan commit 'git commit -m "feat: x"'
check "no -C leaves cpath empty" "" "${GIT_CMD_CPATH[0]}"

git_cmd_scan push 'git push origin main && git -C /tmp/other push origin main'
check "per-invocation cpath: first" "" "${GIT_CMD_CPATH[0]}"
check "per-invocation cpath: second" "/tmp/other" "${GIT_CMD_CPATH[1]}"

# --- arguments after the subcommand ------------------------------------------
git_cmd_scan push 'git --no-pager push --force-with-lease origin feat/x'
check "args exclude git-level options" "--force-with-lease origin feat/x" "${GIT_CMD_ARGS[0]}"

# --- which pushes publish code ------------------------------------------------
publishes() { # publishes <name> <expected-yes|no> <args>
  local want="$2" got="no"
  git_push_publishes_code "$3" && got="yes"
  check "$1" "$want" "$got"
}

publishes "branch push publishes"              yes 'origin main'
publishes "bare push publishes"                yes ''
publishes "force push publishes"               yes '--force origin main'
publishes "--follow-tags publishes"            yes '--follow-tags'
publishes "--follow-tags with remote"          yes '--follow-tags origin'
publishes "--tags with a branch refspec"       yes '--tags origin feature'
publishes "mixed delete and branch publishes"  yes 'origin :dead main'
publishes "bare --tags is exempt"              no  '--tags'
publishes "--tags after remote is exempt"      no  'origin --tags'
publishes "--delete is exempt"                 no  '--delete origin dead'
publishes "-d is exempt"                       no  '-d origin dead'
publishes "colon delete refspec is exempt"     no  'origin :dead'
publishes "push-option value not a refspec"    no  '--push-option=ci.skip origin --tags'

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
