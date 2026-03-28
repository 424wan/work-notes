@echo off
cd /d "%~dp0"
echo Adding all changes...
git add .
echo Committing...
git commit --allow-empty-message -m ""
echo Pushing...
git push
echo Done!
pause
