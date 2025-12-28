#!/bin/bash
#
# Helper script to run Fastlane with proper Ruby environment
# Usage: ./scripts/fastlane.sh <lane> [options]
#
# Examples:
#   ./scripts/fastlane.sh version_info
#   ./scripts/fastlane.sh beta changelog:"First beta"
#   ./scripts/fastlane.sh bump type:minor
#   ./scripts/fastlane.sh release submit:true
#

set -e

# Change to project directory
cd "$(dirname "$0")/.."

# Initialize rbenv
if command -v rbenv &> /dev/null; then
    eval "$(rbenv init -)"
else
    echo "Error: rbenv is not installed. Please install it with: brew install rbenv"
    exit 1
fi

# Check if bundle is available
if ! command -v bundle &> /dev/null; then
    echo "Error: bundler is not installed. Please run: gem install bundler"
    exit 1
fi

# Run fastlane with all arguments
bundle exec fastlane "$@"
