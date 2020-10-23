#!/bin/bash
# Clearn up the macintrash left behind

cd /Volumes/boot
echo "Removing shadows"
find /Volumes/boot/ -name '._*' -delete
echo "Removing DS_Stores"
find /Volumes/boot/ -name '.DS_Store' -delete
rm -r /Volumes/boot/.TemporaryItems
echo "Removing .Spotlights"
rm -r /Volumes/boot/.Spotlight*
