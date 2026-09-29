---
name: deploy
description: Rebuild the CrisisMonitor Docker images (model, backend, frontend) and redeploy them to AWS EC2 and/or Azure App Service. Use when asked to deploy, redeploy, ship, rebuild/push images, or update the live AWS or Azure site. Accepts "aws", "azure", or "all" (default).
---

# Deploy CrisisMonitor

Everything goes through `deploy/deploy.sh`, the same script the
`.github/workflows/deploy_aws_azure.yml` workflow runs on PRs to main. Never
hand-roll `docker build` / `az` / `aws ssm` steps; fix the script instead so CI
stays in sync.

## Topology

| Target | What runs there | URL |
|---|---|---|
| AWS EC2 `i-04900afc624c386ab` (t3.small, us-east-1) | Docker Compose (`deploy/docker-compose.yml`): mongodb, model (:8001), backend (:8000), frontend (:80) | http://32.199.57.44 |
| Azure App Service `crisismonitor_group` (F1) | backend + frontend only; backend calls the **AWS** model and MongoDB | https://crisismonitor-frontend-alice.azurewebsites.net |

Images: AWS pulls from ECR `303936065814.dkr.ecr.us-east-1.amazonaws.com/crisismonitor-*`,
Azure pulls from Docker Hub `excila/crisismonitor-*`. Tags are the git SHA (plus
`-dev<timestamp>` for uncommitted local changes). `NEXT_PUBLIC_API_URL` is baked in at
build time, so each cloud gets its own frontend image.

Secrets live in SSM Parameter Store, not the repo: `/crisismonitor/MONGO_ROOT_PASSWORD`,
`/crisismonitor/WANDB_API_KEY` (the model downloads the `production` model from the W&B
registry on startup).

## Steps

1. **Pick the target** from the user's request: `aws`, `azure`, or `all` (default).
   Azure depends on AWS (model + MongoDB), so a first-ever deploy must include AWS.

2. **Preflight** (run in parallel, stop and report on failure):
   - `docker info` - Docker running
   - `aws sts get-caller-identity` - AWS login (account 303936065814)
   - azure only: `az account show` and `docker login` to Docker Hub as `excila`
   - `git status --short` - mention uncommitted changes in backend/frontend/model/deploy;
     they *will* be deployed (tag gets `-dev<timestamp>`)

3. **Deploy** - this takes 5-15 min (model image is large), so run in the background:
   ```bash
   deploy/deploy.sh <aws|azure|all>
   ```
   The script builds linux/amd64 images, pushes them, rolls out AWS via SSM
   `AWS-RunShellScript` (waits for the model's `/ready`), updates Azure container
   images + app settings, and health-checks each site. Non-zero exit = failure.

4. **Verify** with a real prediction and report the URLs:
   ```bash
   curl -s -X POST http://32.199.57.44:8000/predict-tweet -H 'Content-Type: application/json' \
     -d '{"text":"Forest fire spreading fast near the highway, evacuate now"}'
   ```
   Expect `is_real_disaster` plus a non-zero `disaster_probability`. For Azure use
   `https://crisismonitor-backend-alice.azurewebsites.net/predict-tweet`.
   (Each prediction is stored in MongoDB and shows up in the UI's recent tweets.)

## Troubleshooting

- **SSM parameter missing / AccessDenied on ssm or iam**: one-time setup hasn't been run.
  Ask the user to run `deploy/setup-once.sh` themselves (it grants IAM permissions);
  do not run it or make IAM changes for them.
- **SSM command never starts / `InvalidInstanceId`**: the SSM agent isn't registered -
  the instance role needs `AmazonSSMManagedInstanceCore` (setup-once.sh), then wait ~5 min
  or reboot the instance.
- **Logs on the EC2 host** (no SSH needed):
  ```bash
  id=$(aws ssm send-command --instance-ids i-04900afc624c386ab --document-name AWS-RunShellScript \
       --parameters 'commands=["cd /opt/crisismonitor && docker compose ps && docker compose logs --tail 80"]' \
       --query Command.CommandId --output text)
  aws ssm get-command-invocation --command-id "$id" --instance-id i-04900afc624c386ab \
    --query StandardOutputContent --output text
  ```
- **Model never ready**: usually a bad/expired W&B key -> `RESET_WANDB=1 deploy/setup-once.sh`
  (user runs it). OOM shows as the model container restarting; the host has 2 GB RAM + 2 GB swap.
- **Azure backend 502 on predict**: its outbound IPs must be allowed on ports 8001/27017 of
  security group `sg-0099f760cbf7a837a`; `deploy.sh azure` re-adds them. Logs:
  `az webapp log tail -g crisismonitor_group -n crisismonitor-backend-alice`.
- **Azure slow/503 right after deploy**: F1 cold start, can take several minutes; F1 also has a
  60 CPU-min/day quota.
- **CORS errors in the browser**: add the frontend origin to `origins` in `backend/app/__init__.py`.
