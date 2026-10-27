#!/bin/bash

read -p "Did you update the version before running this? (y/N) " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    
    echo "Creating production release"
    
    if [ "$1" != "--skip-build" ]; then
        flutter build apk --release --flavor standard
    fi
    
    echo "Uploading release..."
    echo "If distribution fails, firebase login:use <email> to change account."
    
    firebase appdistribution:distribute \
        build/app/outputs/flutter-apk/app-standard-release.apk \
        --app '1:1001367850451:android:bea525abb82ed76d75b326' \
        --groups 'alpha-testers'
    
fi
