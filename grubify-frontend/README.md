# Grubify Frontend

React 18 + TypeScript frontend for the Grubify food delivery app, built with Material-UI and deployed to Azure Container Apps.

## Tech Stack

- React 18 + TypeScript
- Material-UI (MUI v7)
- React Router v6
- Axios for API calls

## Local Development

```bash
npm install
npm start
```

Opens at [http://localhost:3000](http://localhost:3000). The app proxies API calls to the backend at `http://localhost:5291`.

## Available Scripts

| Script | Description |
|---|---|
| `npm start` | Run in development mode with hot reload |
| `npm run build` | Build for production into `build/` |
| `npm test` | Run tests in interactive watch mode |

## Environment Variables

| Variable | Description |
|---|---|
| `REACT_APP_API_BASE_URL` | Backend API base URL (injected at container startup) |

In production, the Docker entrypoint script substitutes `REACT_APP_API_BASE_URL` into the built JS bundle at container startup — no rebuild needed.

## Deployment

The container image is built in **Azure Container Registry** using ACR Tasks (no local Docker required). See the root `azure.yaml` and `README.md` for full deployment instructions.
