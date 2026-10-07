#!/bin/zsh
cd "${0:A:h:h}" || exit 1
python3 scripts/clean-keychain-authorizations.py --apply
result=$?
printf '\n按回车关闭窗口。'
read -r
exit "$result"
