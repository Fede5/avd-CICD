# AVD Session Host Rolling Update via CI/CD 🚀

![Azure](https://img.shields.io/badge/Azure-0078D4?logo=microsoftazure&logoColor=white)
![Bicep](https://img.shields.io/badge/Bicep-005BA1?logo=microsoft&logoColor=white)
![PowerShell](https://img.shields.io/badge/PowerShell-5391FE?logo=powershell&logoColor=white)
![Azure DevOps](https://img.shields.io/badge/Azure_DevOps-CB2C2F?logo=azuredevops&logoColor=white)
![CI/CD](https://img.shields.io/badge/CI/CD-Phased-blue)

This project provides a fully automated and safe solution for **rolling updates of Azure Virtual Desktop (AVD) session hosts** using the **latest image from Azure Compute Gallery**.

---

## 🧠 Key Features

- Triggered by new custom image publication
- Supports multiple host pools (DEV, PROD)
- Phased rollout strategy based on tags
- Bicep modules for modular deployment
- Secrets managed via Azure Key Vault
- Session drain and safe removal of outdated hosts

---

## 📁 Project Structure

```
📦 avd-sessionhost-update/
├── avd-host-update-pipeline.yml          # Single-step pipeline to update AVD hosts
├── avd-host-update-phased-pipeline.yml   # Multi-stage pipeline (Testing → Approval → Production)
│
├── modules/
│   ├── sessionhosts.bicep
│   ├── sessionhosts-update.bicep
│   └── vm-deploy-loop-update.bicep
```

---

## 🚀 How It Works

1. **Trigger**: Event Grid detects new `galleryImageVersionId`
2. **Phase 1**: Deploy to `AVDEnvironment=Testing` host pools
3. **Manual Approval**
4. **Phase 2**: Deploy to `AVDEnvironment=Production` host pools
5. **Each Session Host:**
   - Set drain mode
   - Wait for active sessions to complete
   - Deploy new VM with latest image
   - Register to AVD
   - Delete old VM/NIC/disk
   - Tag host with image version ID

---

## 🧩 Parameters

- `vmAdminUsername`, `vmAdminPassword` (from Key Vault)
- `domainJoinUsername`, `domainJoinPassword`
- `galleryImageVersionId` (triggered or manually passed)

---

## 🛡 Security Best Practices

- All credentials fetched securely from Azure Key Vault
- Tokens and secrets never exposed in logs
- Hosts drained before deletion
- All VMs tagged for traceability

---

## 📋 Demo Input Payload

```json
{
  "sourceImageVersionId": "/subscriptions/xxxx/resourceGroups/rg-avd-images/providers/Microsoft.Compute/galleries/avd-gallery/images/win11-24h2-avd/versions/1.0.20240406"
}
```

---

## 📌 Requirements

- Azure DevOps pipeline with Service Connection
- Azure Key Vault with necessary secrets
- Azure Compute Gallery with custom image
- Existing AVD infrastructure

---

## ✍️ Author

**Harry Federico Argote Carrasco**  
Senior Cloud Engineer | Azure Specialist  
📍 Bella Vista, Buenos Aires, Argentina

---

> This project is designed for scalable enterprise environments. Fork, improve, and contribute!
