<!-- Use this file to provide workspace-specific custom instructions to Copilot. For more details, visit https://code.visualstudio.com/docs/copilot/copilot-customization#_use-a-githubcopilotinstructionsmd-file -->

# Grubify Food Delivery App

This is a modern food delivery application with a React TypeScript frontend and .NET backend, designed for deployment to Azure Container Apps.

## Tech Stack
- **Frontend**: React 18 with TypeScript, Material-UI, React Router
- **Backend**: .NET 9 Web API with Controllers
- **Deployment**: Azure Container Apps via Azure Developer CLI (azd)
- **Infrastructure**: Bicep templates
- **Container Build**: ACR Tasks (remote build in Azure Container Registry — no local Docker required)

## Architecture
- Clean separation between frontend and backend
- RESTful API design
- Responsive Material-UI components
- Azure Container Apps for scalable hosting
- Images built directly in ACR using `docker.remoteBuild: true` in `azure.yaml`
- Container Apps pull images from ACR via user-assigned managed identity (AcrPull role)

## Development Guidelines
- Use TypeScript strict mode
- Follow Material-UI design patterns
- Implement proper error handling
- Use async/await for API calls
- Follow RESTful conventions for API endpoints

## API Endpoints
- `/api/restaurants` - Restaurant management
- `/api/fooditems` - Food item management  
- `/api/cart` - Shopping cart operations
- `/api/orders` - Order management

## UI Components
- Modern, responsive design inspired by popular food delivery apps
- Card-based layouts for restaurants and food items
- Step-by-step checkout process
- Real-time order tracking

## Deployment
- Region: `swedencentral` (required for SRE Agent preview)
- Run `azd up` to provision infrastructure and deploy — no Docker Desktop needed
- See `azure.yaml` for service definitions and `infra/` for Bicep templates

When working on this project, prioritize user experience, maintain clean code architecture, and ensure proper error handling throughout the application.
