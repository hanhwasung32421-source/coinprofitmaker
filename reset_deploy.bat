@echo off
cd C:\trae
git checkout --orphan temp-main
git add -A
git commit -m "reset & deploy"
git push -f origin temp-main:main
git checkout main
git branch -D temp-main
