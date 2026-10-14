#!/usr/bin/env bash
# builds the sioyek-ai chat window and installs it to ~/.config/sioyek/bin/sioyek-ai
set -e
cd "$(dirname "$0")"
mkdir -p ~/.config/sioyek/bin
swiftc -O -swift-version 5 -framework AppKit -framework PDFKit SioyekAI.swift -o ~/.config/sioyek/bin/sioyek-ai
echo "installed ~/.config/sioyek/bin/sioyek-ai"
