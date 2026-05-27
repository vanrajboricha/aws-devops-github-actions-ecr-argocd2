#!/bin/bash

# Get commit message from argument, default to "Welcome to StackSimplify"
COMMIT_MSG="${1:-Welcome to StackSimplify}"

echo "...........ADDING ALL FILES ..........."
git add .

echo "...........COMMITING CHANGES .........."
git commit -m "$COMMIT_MSG"

echo "Pushing to GitHub..."
git push

echo "...........Git ADD, COMMIT and PUSH - COMPLETED!!!!!!!!"