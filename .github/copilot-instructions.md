<!-- Use this file to provide workspace-specific custom instructions to Copilot. For more details, visit https://code.visualstudio.com/docs/copilot/copilot-customization#_use-a-githubcopilotinstructionsmd-file -->

# Grubify Food Delivery App

This is a modern food delivery application with a React TypeScript frontend and .NET backend, designed for deployment to Azure Container Apps.

## Tech Stack
- **Frontend**: React 19 with TypeScript, Material-UI, React Router
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

## Data Storage
- **In-memory only** — no database. Hardcoded sample restaurants and food items. Carts and orders stored in static dictionaries (reset on restart).

## API Endpoints
- `/api/restaurants` — List, get by ID, filter by cuisine, search
- `/api/fooditems` — List, get by ID, filter by restaurant/category/dietary, search
- `/api/cart/{userId}` — Get cart, add/update/remove items, clear
- `/api/orders` — Place order, get by ID/user, active orders, cancel, update status

## Frontend Pages & Routes
- `/` — HomePage (browse restaurants, cuisine filters, search)
- `/restaurant/:id` — RestaurantPage (menu items, add-to-cart dialog)
- `/cart` — CartPage (review items, quantities, totals)
- `/checkout` — CheckoutPage (multi-step: address → payment → review)
- `/order-tracking/:orderId` — OrderTrackingPage (status stepper)

## UI Components
- **Navbar** — Logo, search bar, sign-in button, cart badge
- Card-based layouts for restaurants and food items
- Step-by-step checkout process with Material-UI Stepper
- Order tracking with visual status progression

## SRE Demo Context
- **Cart endpoint** no longer retains request buffers; carts remain in-memory and reset on restart
- **Orders endpoint** switches between v1 (working) and v2 (broken payment gateway) via `API_VERSION` env var
- `WeatherForecastController.cs` is unused template code — ignore it

## Deployment
- Region: `swedencentral` (required for SRE Agent preview)
- Run `azd up` to provision infrastructure and deploy — no Docker Desktop needed
- See `azure.yaml` for service definitions and `infra/` for Bicep templates
- Three azd services: `api` (Container App), `frontend` (Container App), `governance` (Function App)

When working on this project, prioritize user experience, maintain clean code architecture, and ensure proper error handling throughout the application.
