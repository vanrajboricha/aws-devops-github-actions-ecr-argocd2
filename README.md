# GitHub Actions CI: Build & Push UI Microservice to AWS ECR

This guide establishes a **secure, GitOps-ready CI pipeline** using GitHub Actions with **OIDC authentication** (no AWS keys stored in GitHub!). The pipeline automatically builds, tags, and pushes Docker images to Amazon ECR, then updates Helm values to trigger ArgoCD deployments.

---

## Prerequisites

Before starting, ensure you have:

- [x] AWS CLI configured with appropriate permissions
- [x] GitHub repository with `ui` microservice code
- [x] Basic understanding of Docker, ECR, and Helm
- [x] GitHub Actions enabled in your repository

---

## What This Pipeline Achieves
```
Code Change -> GitHub Actions -> Build Image -> Push to ECR -> Update Helm Values -> ArgoCD Deploys
```

**Key Features:**
- **Secure OIDC authentication** (no long-lived AWS credentials)
- **Dual tagging strategy** (`latest` + `sha-commit`)
- **GitOps-ready** (auto-updates Helm values)
- **Fast, automated CI** triggered on code changes

### GitOps Full Flow (DevOps CI and CD combined flow)
```
Developer Pushes Code to src/ui/src/**
            |
            | (1) Triggers GitHub Actions workflow
            v
    GitHub Actions Runner
            |
            | (2) Builds Docker image
            | (3) Pushes to ECR with tags: latest + sha-a1b2c3d
            | (4) Updates chart/values-ui.yaml (tag: sha-a1b2c3d)
            | (5) Commits and pushes to Git
            v
       Git Repository (main branch)
            |
            | (6) ArgoCD polls Git every 3 minutes
            v
      ArgoCD Detects Change
            |
            | (7) Syncs and deploys new image
            v
        EKS Cluster (Running Pods)
```



### CI Pipeline Flow
![CI Pipeline Flow](../../images/21_01_01_GitOps_CI.png)

---
### Other Images for Reference
![CI Pipeline Flow](../../images/21_01_02_github_actions.png)

---
![CI Pipeline Flow](../../images/21_01_03_github_actions.png)

---
![CI Pipeline Flow](../../images/21_01_04_ecr_image.png)

---
![CI Pipeline Flow](../../images/21_01_05_values_ui_image_tag.png)

---

## Step-01: Create ECR Repository
```bash
# Create ECR repository for UI microservice
aws ecr create-repository \
  --repository-name retail-store/ui \
  --region us-east-1

# Expected output:
# {
#     "repository": {
#         "repositoryArn": "arn:aws:ecr:us-east-1:123456789012:repository/retail-store/ui",
#         "repositoryName": "retail-store/ui",
#         "repositoryUri": "123456789012.dkr.ecr.us-east-1.amazonaws.com/retail-store/ui"
#     }
# }
```

**Note:** Save the `repositoryUri` - you'll need it later!

---

## Step-02: Create GitHub OIDC IAM Role

### Step-02-01: Set Environment Variables
```bash
# Set your configuration
AWS_REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
GITHUB_REPO="stacksimplify/aws-devops-github-actions-ecr-argocd3"  # UPDATE with YOUR repo
ROLE_NAME="github-actions-oidc-role-ui3"

# Verify variables are set correctly
echo "AWS Region: $AWS_REGION"
echo "Account ID: $ACCOUNT_ID"
echo "GitHub Repo: $GITHUB_REPO"
echo "IAM Role Name: $ROLE_NAME"
```

**IMPORTANT:** Replace `GITHUB_REPO` with your actual repository path (format: `owner/repo-name`)

---

### Step-02-02: Generate Trust Policy
```bash
# Generate trust-policy.json with automatic variable substitution
cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_REPO}:*"
        }
      }
    }
  ]
}
EOF

# Verify the generated file
echo "Trust policy created. Contents:"
cat trust-policy.json
```

**What this does:** Allows GitHub Actions from your repository to assume this IAM role using OIDC tokens (no AWS keys needed!)

---

### Step-02-03: Create IAM Role
```bash
# Verify the trust policy before creating role
cat trust-policy.json | jq '.'

# Create the IAM role
aws iam create-role \
  --role-name $ROLE_NAME \
  --assume-role-policy-document file://trust-policy.json

# Expected output:
# {
#     "Role": {
#         "RoleName": "github-actions-oidc-role-ui3",
#         "Arn": "arn:aws:iam::123456789012:role/github-actions-oidc-role-ui3",
#         ...
#     }
# }
```

**Copy the Role ARN** - you'll need it in Step-03!

---

### Step-02-04: Attach ECR Permissions
```bash
# Attach AWS managed policy for ECR push/pull access
aws iam attach-role-policy \
  --role-name $ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser

# Verify policy is attached
aws iam list-attached-role-policies --role-name $ROLE_NAME
```

**What this grants:**
- [x] Push images to ECR
- [x] Pull images from ECR
- [x] Manage ECR repositories
- [x] Get ECR authentication tokens

---

### Step-02-05: Create the OIDC Provider in Your AWS Account

```bash
# List OIDC Providers
aws iam list-open-id-connect-providers

# Create OIDC Provider
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com 

# List OIDC Providers
aws iam list-open-id-connect-providers
```

---

## Step-03: Configure GitHub Actions Workflow

### Step-03-00: Create GitHub Repository and Copy Files
- **Repo Name:** aws-devops-github-actions-ecr-argocd2
- **COPY FILES:** COPY ALL FILES FROM `**github-files**` directory


### Step-03-01: Update Workflow File

Edit `.github/workflows/build-push-ui.yaml` and update the **role ARN**:
```yaml
- name: Configure AWS credentials via OIDC
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::<ACCOUNT_ID>:role/github-actions-oidc-role-ui3  # Replace <ACCOUNT_ID>
    aws-region: ${{ env.AWS_REGION }}
```

**Replace `<ACCOUNT_ID>`** with your actual AWS account ID from Step-02-01.

### Step-03-02: Verify Workflow Configuration

**Key workflow settings to verify:**
```yaml
env:
  AWS_REGION: us-east-1                    # Your region
  ECR_REPOSITORY: retail-store/ui          # Your ECR repo name

permissions:
  id-token: write   # Required for OIDC
  contents: write   # Required to commit Helm updates
```

**Full workflow file reference:** [`.github/workflows/build-push-ui.yaml`](https://github.com/stacksimplify/aws-devops-github-actions-ecr-argocd3/blob/main/.github/workflows/build-push-ui.yaml)

---

## Step-04: Push Configuration to GitHub
```bash
# Navigate to your repository
cd aws-devops-github-actions-ecr-argocd3

# Stage all changes
git add .

# Commit with descriptive message
git commit -m "Add GitHub Actions CI workflow for UI microservice"

# Push to main branch (triggers the workflow!)
git push origin main
```

**Note:** This initial push will NOT trigger the workflow because no changes were made to `src/ui/src/**`. We'll test it in Step-06.

---

## Step-05: Understanding the Workflow

### What This Workflow Does

| Step | Action | Description |
|------|--------|-------------|
| **1. Checkout code** | `actions/checkout@v4` | Clones repository code to GitHub Actions runner |
| **2. Configure AWS credentials** | `configure-aws-credentials@v4` | Uses **OIDC** to assume IAM role (keyless auth) |
| **3. Login to Amazon ECR** | `amazon-ecr-login@v2` | Authenticates Docker with ECR using temporary credentials |
| **4. Define image tags** | Shell script | Generates `latest` and `sha-<commit>` tags (e.g., `sha-a1b2c3d`) |
| **5. Build and push images** | `docker build` + `docker push` | Builds image once, pushes **both tags** to ECR |
| **6. Setup Git auth** | Git config | Configures `ci-bot` identity with `GITHUB_TOKEN` |
| **7. Update Helm values** | `sed` + `git commit/push` | Updates `chart/values-ui.yaml` with SHA tag, pushes to Git |
| **8. CI Complete** | Log output | Confirms successful completion |

---

### Why Two Image Tags?

The workflow pushes the **same Docker image** with two different tags:

#### 1. `latest` Tag
- **Purpose:** Convenience reference for local testing
- **Behavior:** Mutable (always points to most recent build)
- **Used in:** Local development, debugging
- **NOT used in:** Production Helm charts

#### 2. `sha-<commit>` Tag (Example: `sha-a1b2c3d`)
- **Purpose:** Immutable reference tied to Git commit
- **Behavior:** Never changes (permanent)
- **Used in:** `chart/values-ui.yaml` (production deployments)
- **Benefits:** 
  - [x] Full traceability (Git commit -> Docker image -> Deployment)
  - [x] Safe rollbacks to exact versions
  - [x] Prevents "tag drift" issues

**Example in Helm values file:**
```yaml
image:
  repository: 180789647333.dkr.ecr.us-east-1.amazonaws.com/retail-store/ui
  tag: sha-a1b2c3d  # SHA tag only (immutable)
  # NOT using "latest" - too risky for production!
```

---

### GitOps Flow Explained
```
Developer Pushes Code to src/ui/src/**
            |
            | (1) Triggers GitHub Actions workflow
            v
    GitHub Actions Runner
            |
            | (2) Builds Docker image
            | (3) Pushes to ECR with tags: latest + sha-a1b2c3d
            | (4) Updates chart/values-ui.yaml (tag: sha-a1b2c3d)
            | (5) Commits and pushes to Git
            v
       Git Repository (main branch)
            |
            | (6) ArgoCD polls Git every 3 minutes
            v
      ArgoCD Detects Change
            |
            | (7) Syncs and deploys new image
            v
        EKS Cluster (Running Pods)
```

**Key Principle:** Git is the **single source of truth** for both code and deployment state!

---

## Step-06: Test the CI Pipeline

### Step-06-01: Make a Code Change

Let's update the UI version to trigger the workflow:
```bash
# Sync your local repo (always pull latest first!)
git pull origin main
or
./git-pull.sh

# Option 1: Use provided script
./update-ui-home-html.sh V102

# Option 2: Manual edit
# Edit src/ui/src/home.html and change the version:
```

**Find this line:**
```html
<h1 class="text-4xl sm:text-5xl font-bold text-white mb-6">
  The most public <span class="text-primary-400">Secret Shop - Version: V101</span>
</h1>
```

**Change to:**
```html
<h1 class="text-4xl sm:text-5xl font-bold text-white mb-6">
  The most public <span class="text-primary-400">Secret Shop - Version: V102</span>
</h1>
```

---

### Step-06-02: Commit and Push
```bash
# Stage changes
git add src/ui/src/home.html

# Commit with version in message
git commit -m "Update UI to Version V102"

# Push to trigger workflow
git push origin main

or
./git-push.sh
```

**SUCCESS:** Workflow will trigger automatically because we modified `src/ui/src/**`

---

## Step-07: Monitor GitHub Actions Workflow

### Step-07-01: Watch the Pipeline

1. Go to your GitHub repository
2. Click **Actions** tab
3. You should see a new workflow run: **"Build and Push UI Service to ECR"**

**Live example:** [GitHub Actions for this Repo](https://github.com/stacksimplify/aws-devops-github-actions-ecr-argocd3/actions)

**Expected timeline:**
- Checkout code: ~5 seconds
- Configure AWS + Login ECR: ~10 seconds
- Build Docker image: ~20-40 seconds
- Push to ECR: ~10-20 seconds
- Update Helm values: ~5 seconds
- **Total: ~1-2 minutes**

---

### Step-07-02: Verify Successful Completion

Look for these success indicators in the logs:
```
[PASS] Checkout code                        
[PASS] Configure AWS credentials via OIDC   
[PASS] Login to Amazon ECR                  
[PASS] Define image tags                    
[PASS] Build and push Docker images         
[PASS] Setup Git auth using GITHUB_TOKEN    
[PASS] Update Helm values file              
[PASS] CI Complete                          
```

---

## Step-08: Validate CI Outputs

### Step-08-01: Verify ECR Image

**Option 1: AWS Console**
1. Go to **Amazon ECR** -> **Repositories** -> `retail-store/ui`
2. You should see two new image tags:
   - `latest`
   - `sha-a1b2c3d` (your actual commit SHA)

**Option 2: AWS CLI**
```bash
# List all images in the repository
aws ecr describe-images \
  --repository-name retail-store/ui \
  --region us-east-1

# Expected output:
# {
#     "imageDetails": [
#         {
#             "imageTags": ["latest", "sha-a1b2c3d"],
#             "imagePushedAt": "2025-01-02T...",
#             "imageSizeInBytes": 123456789
#         }
#     ]
# }
```

---

### Step-08-02: Verify Updated Helm Values File

**Option 1: GitHub Web UI**
1. Navigate to [`src/ui/chart/values-ui.yaml`](https://github.com/stacksimplify/aws-devops-github-actions-ecr-argocd3/blob/main/src/ui/chart/values-ui.yaml)
2. Look for the `image.tag` field
3. It should show the **new SHA tag** that was just pushed

**Option 2: Git Pull and Check Locally**
```bash
# Pull latest changes (includes the automated commit)
git pull origin main

# View the updated values file
cat src/ui/chart/values-ui.yaml | grep -A 2 "image:"

# Expected output:
# image:
#   repository: 180789647333.dkr.ecr.us-east-1.amazonaws.com/retail-store/ui
#   tag: sha-a1b2c3d
```

**Option 3: Check Git Commit History**
```bash
# View recent commits
git log --oneline -5

# You should see a commit from "ci-bot":
# a1b2c3d Update UI image tag to sha-a1b2c3d
# ...
```

---

### Step-08-03: Understanding the Image URIs

Your Docker images are now available at these URIs:
```bash
# Latest tag (mutable)
180789647333.dkr.ecr.us-east-1.amazonaws.com/retail-store/ui:latest

# SHA tag (immutable - used in production)
180789647333.dkr.ecr.us-east-1.amazonaws.com/retail-store/ui:sha-a1b2c3d
```


---

## Troubleshooting

### Issue 1: Workflow Not Triggering

**Symptom:** No workflow run appears after pushing code

**Causes & Solutions:**

| Cause | Solution |
|-------|----------|
| Changes not in `src/ui/src/**` | Verify you modified files in the correct path |
| Workflow file syntax error | Check `.github/workflows/build-push-ui.yaml` with a YAML validator |
| Workflow disabled | Go to Actions -> Enable workflows if disabled |

---

### Issue 2: OIDC Authentication Fails

**Symptom:** Error: "Not authorized to perform sts:AssumeRoleWithWebIdentity"

**Solutions:**
```bash
# 1. Verify OIDC provider exists in IAM
aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com

# 2. If not found, create it:
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

# 3. Verify trust policy has correct GitHub repo
aws iam get-role --role-name github-actions-oidc-role-ui3 | jq '.Role.AssumeRolePolicyDocument'

# 4. Ensure repository name matches exactly (case-sensitive!)
```

---

### Issue 3: ECR Push Failed

**Symptom:** Error: "denied: User is not authorized to perform ecr:PutImage"

**Solution:**
```bash
# Verify policy is attached
aws iam list-attached-role-policies --role-name github-actions-oidc-role-ui3

# Re-attach if missing
aws iam attach-role-policy \
  --role-name github-actions-oidc-role-ui3 \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
```

---

### Issue 4: Git Push to Helm Values Failed

**Symptom:** Error: "fatal: could not read Username"

**Causes:**
- `GITHUB_TOKEN` permissions insufficient
- Repository settings blocking pushes from Actions

**Solution:**
1. Go to **Repository Settings** -> **Actions** -> **General**
2. Scroll to **Workflow permissions**
3. Select **"Read and write permissions"**
4. Save changes and re-run workflow

---

### Issue 5: Docker Build Fails

**Symptom:** Error during "Build and push Docker images" step

**Debug steps:**
```bash
# Test Docker build locally
cd src/ui
docker build -t test-ui .

# Check Dockerfile syntax
cat Dockerfile

# Verify all required files exist
ls -la
```

---

## Success Checklist

After completing all steps, verify:

- [x] ECR repository `retail-store/ui` exists
- [x] IAM role `github-actions-oidc-role-ui3` created with OIDC trust policy
- [x] ECR push policy attached to IAM role
- [x] GitHub Actions workflow file updated with correct role ARN
- [x] Workflow triggered on code push to `src/ui/src/**`
- [x] Two image tags pushed to ECR (`latest` + `sha-<commit>`)
- [x] Helm `values-ui.yaml` updated with SHA tag
- [x] Git commit from `ci-bot` visible in repository history

---

## Next Steps

Now that your CI pipeline is working:

1. **Set up ArgoCD** to watch the `chart/values-ui.yaml` file
2. **Configure Auto-Sync** in ArgoCD to deploy on Git changes
3. **Test the full CD flow** by making another UI change
4. **Replicate for other microservices** (catalog, cart, checkout, assets)

---

## Additional Resources

- **GitHub Repository:** [aws-devops-github-actions-ecr-argocd3](https://github.com/stacksimplify/aws-devops-github-actions-ecr-argocd3)
- **Workflow File:** [`.github/workflows/build-push-ui.yaml`](https://github.com/stacksimplify/aws-devops-github-actions-ecr-argocd3/blob/main/.github/workflows/build-push-ui.yaml)
- **AWS OIDC with GitHub Actions:** [Official Documentation](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
- **ArgoCD GitOps Guide:** [Getting Started](https://argo-cd.readthedocs.io/en/stable/getting_started/)

---

## Summary

You've successfully built a **production-ready CI pipeline** with:

- **Zero secrets stored in GitHub** (OIDC-based authentication)
- **Immutable image tagging** (SHA-based versioning)
- **GitOps-ready workflow** (auto-updates Helm values)
- **Fast, automated builds** (triggers on code changes)
- **ECR integration** (secure, private container registry)

**Your images are now ready for ArgoCD to deploy to EKS!**

