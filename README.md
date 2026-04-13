# Grubify - Food Delivery App

A modern food delivery application built with React TypeScript frontend and .NET backend, designed for deployment to Azure Container Apps using Azure Developer CLI (azd).

## 🍕 Features

- **Modern UI**: Beautiful, responsive design inspired by popular food delivery apps
- **Real Food Content**: Sample restaurants and food items with real images from Unsplash
- **Complete Food Delivery Flow**: Browse restaurants → Add to cart → Checkout → Track orders
- **Azure Container Apps**: Scalable, serverless container hosting
- **Azure Developer CLI**: One-command deployment and management

## 🏗️ Architecture

- **Frontend**: React 18 + TypeScript + Material-UI
- **Backend**: .NET 9 Web API with RESTful endpoints
- **Infrastructure**: Azure Container Apps + Azure Container Registry (ACR)
- **Deployment**: Azure Developer CLI (azd) with remote ACR builds — no local Docker required

## 🚀 Complete Deployment Guide

This guide shows how to deploy Grubify with **both backend versions** (v1 with memory leak, v2 with payment failures) for testing Azure SRE Agent scenarios.

## 📋 Prerequisites

Before deploying Grubify, ensure you have the following tools installed:

### Required Tools
- **[Azure Developer CLI (azd)](https://learn.microsoft.com/en-us/azure/developer/azure-developer-cli/install-azd)** - Latest version
- **[Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)** - For additional Azure operations
- **Azure Subscription** - With Contributor/Owner permissions

> **Note**: Docker Desktop is **not required**. Container images are built directly in Azure Container Registry using ACR Tasks (remote builds).

## 🚀 Quick Start

### 1. Prerequisites Check
Before starting, run the automated prerequisites check script:

```bash
./scripts/check-prerequisites.sh
```

### 2. Initial Azure Setup

```bash
# Clone the repository
git clone https://github.com/gderossilive/GrubifyDemo.git
cd GrubifyDemo

# Login to Azure
azd auth login
az login --use-device-code

# Initialize azd environment
azd init

# Set Azure location (must be swedencentral — SRE Agent preview constraint)
azd env set AZURE_LOCATION swedencentral
```

### 3. Deploy Infrastructure & Applications

```bash
# Deploy infrastructure and applications
azd up
```

This creates:
- **Resource Group**: `rg-grubify-app`
- **Container Registry**: `crgrubify` — images are built here via ACR Tasks
- **Container Apps Environment**: `cae-grubify`
- **API Container App**: `ca-grubify-api`
- **Frontend Container App**: `ca-grubify-frontend`
- **Log Analytics Workspace**: `log-grubify`

### 4. Ready for SRE Scenarios

Now you have:
- ✅ **Frontend deployed** and working
- ✅ **Backend deployed** and working
- ✅ **Infrastructure configured** for testing scenarios

**SRE Agent Setup:**
1. **Create agent** - ([Azure SRE Agent Usage Guide](https://learn.microsoft.com/en-us/azure/sre-agent/usage))
2. **Map GitHub repo**: **https://github.com/gderossilive/GrubifyDemo**
3. **Connect ServiceNow** to your SRE agent
4. **Setup incident handler** with custom instructions for automated diagnosis and mitigation
5. **Simulate memory leak** using the deployed application endpoints
6. **Create incident in ServiceNow** to trigger SRE agent response

