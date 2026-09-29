RESOURCE_GROUP="crisismonitor_group"
LOCATION="northcentralus"
PLAN_NAME="crisismonitor-plan"
WEBAPP_NAME="crisismonitor-frontend-alice"
IMAGE_NAME="excila/crisismonitor-frontend:latest"
PORT="80"         # Container exposed port

# ---- CREATE WEB APP ----
echo "Creating Web App: $WEBAPP_NAME ..."
az webapp create \
  --resource-group "$RESOURCE_GROUP" \
  --plan "$PLAN_NAME" \
  --name "$WEBAPP_NAME" \
  --container-image-name "$IMAGE_NAME"

# ---- SET APP SETTINGS ----
echo "Setting environment variables ..."
az webapp config appsettings set \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEBAPP_NAME" \
  --settings PORT="$PORT"

# ---- SHOW DEPLOYMENT INFO ----
echo "Deployment complete!"
az webapp show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEBAPP_NAME" \
  --query "{url: defaultHostName, status: state}"
