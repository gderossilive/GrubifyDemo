#!/bin/bash

echo "🔍 Checking Grubify Deployment Prerequisites..."
echo "============================================="

EXIT_CODE=0

# Docker is NOT required — images are built remotely in ACR using ACR Tasks
echo -n "Docker (optional): "
if docker ps > /dev/null 2>&1; then
    echo "✅ Running (not required — builds run in ACR)"
else
    echo "ℹ️  Not running — OK, container images are built in Azure Container Registry"
fi

# Check Azure CLI
echo -n "Azure CLI: "
if az --version > /dev/null 2>&1; then
    echo "✅ Installed"
else
    echo "❌ Not installed - Install from https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
    EXIT_CODE=1
fi

# Check Azure Developer CLI
echo -n "Azure Developer CLI: "
if azd version > /dev/null 2>&1; then
    echo "✅ Installed"
else
    echo "❌ Not installed - Install from https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/install-azd"
    EXIT_CODE=1
fi

# Check Azure authentication
echo -n "Azure Authentication: "
if az account show > /dev/null 2>&1; then
    echo "✅ Logged in"
else
    echo "⚠️  Not logged in - Run 'az login --use-device-code'"
fi

echo "============================================="

if [ $EXIT_CODE -eq 0 ]; then
    echo "🎉 All prerequisites are ready!"
    echo "You can now run: azd up"
else
    echo "❌ Please fix the issues above before running azd up"
fi

exit $EXIT_CODE
