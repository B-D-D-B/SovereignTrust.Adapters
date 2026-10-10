# 🧩 SovereignTrust.Adapters

**Adapters for SovereignTrust Attachment System**  
_Repository of modular PowerShell adapters for runtime memory, file systems, and external services._

---

## 📦 Purpose

This repository provides **pluggable adapters** for the SovereignTrust protocol. Each adapter defines a specific interaction layer (e.g. local storage, Azure queues) and includes all necessary modules, manifests, and runtime trainers for integration into SovereignTrust’s signal-driven, memory-sovereign runtime.

Adapters are hosted under:
```
/Src/{Kind}/{Subkind}/PowerShell/
```

Each folder contains:
- `.psd1` — Module definition
- `.psm1` — PowerShell implementation
- `.Manifest.ps1` — Sovereign manifest structure
- `.Trainer.ps1` — Setup/configuration automation
- `.Manifest.json` — Serialized identity and wire binding
- `*.ps1` — Optional test harnesses or examples

---

## 📂 Current Adapters

### 📮 Azure Storage Queue
```
Src/Network/AzureStorageQueue/PowerShell/
```
Enables SovereignTrust to relay and receive messages via Azure Storage Queues.

Files:
- `SovereignTrust.Adapters.Network.AzureStorageQueue.psm1`
- `SovereignTrust.Adapters.Network.AzureStorageQueue.Manifest.json`
- `SovereignTrust.Adapters.Network.AzureStorageQueue.Trainer.ps1`

### 🗂 Local File System
```
Src/Storage/LocalFileSystem/PowerShell/
```
Provides read/write access to local disk storage as a memory attachment.

Files:
- `SovereignTrust.Adapters.Storage.LocalFileSystem.psm1`
- `SovereignTrust.Adapters.Storage.LocalFileSystem.Manifest.json`
- `SovereignTrust.Adapters.Storage.LocalFileSystem.Trainer.ps1`

---

## 🛠 How to Use

1. Add to your local or remote SovereignTrust runtime with `Import-Module`.
2. Run the `Trainer.ps1` script to configure paths and test functionality.
3. Register the adapter in your Graph using:
```powershell
$graph.RegisterResultAsSignal("Storage", $adapterInstance)
```

4. Reference with a VirtualPath like:
```
@@@Storage[Path='Logs/Summary.json']
```

---

## Ownership and collaboration

BDDB LLC is the current copyright holder for the rights it owns in this project. Silicon Dream Artists SPC collaborates on the project. Licensed under MIT.

## 📜 License

MIT License • © 2025 Silicon Dream Artists (SDA)

See `LICENSE` for full terms.

---

## ✨ Maintained by Neural Alchemist + Shadow PhanTom
