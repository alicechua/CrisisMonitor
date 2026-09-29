#!/bin/bash
set -e

# ---------- Install dependencies ----------
sudo dnf update -y
sudo dnf install -y docker awscli
sudo systemctl enable docker
sudo systemctl start docker


# ---------- Fetch model service IP ----------
WANDB_API_KEY=$(aws ssm get-parameter \
  --name "/mlapp/model/WandbApiKey" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text 2>/dev/null || echo "")

# ---------- Run Model ----------
sudo docker run -d --restart always \
  --name model \
  -p 80:80 \
  -e "WANDB_API_KEY=${WANDB_API_KEY}" \
  viriyadhika/disaster-classification-mscac-model:latest
