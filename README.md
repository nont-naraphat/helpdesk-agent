# helpdesk-agent

Endpoint helpdesk agent + control portal for the SunPassion Windows fleet.

พนักงานเครื่องมีปัญหา -> เปิด portal บน NAS_02 -> เลือกเครื่อง -> กด collect
ข้อมูล (sysinfo / network / Defender / event log / files ...) -> ดูผลในเว็บ
ทุกคำสั่งต้อง **Confirm** ก่อน และลง **audit log** ทุกครั้ง

Agent เป็น **outbound-only** (poll ทุก 30 วิ) ไม่เปิด port ฟังบนเครื่องพนักงาน

---

## โครงสร้างไฟล์

```
helpdesk-agent/
  server/                     <- รันบน NAS_02 (Docker)
    main.py                   FastAPI + SQLite + audit
    static/index.html         Web UI (หน้าเดียวจบ)
    Dockerfile
    docker-compose.yml        map port 8097 -> 8000
    requirements.txt
  agent/                      <- package เป็น Intune Win32 app
    agent.ps1                 ตัว agent (loop 30s, collectors)
    install.ps1               ตัวติดตั้ง (แก้ค่าก่อน package)
    uninstall.ps1
  .env.example                copy เป็น .env บน NAS_02
  .gitignore
  push.bat
  README.md
```

---

## PART 1 — เอาขึ้น Git

จากเครื่อง Windows ที่มี repo:

```cmd
cd path\to\helpdesk-agent
git init
git remote add origin https://github.com/nont-naraphat/helpdesk-agent.git
push.bat "initial commit"
```

> `.env` และ `server/data/` ถูก ignore อยู่แล้ว -> secret ไม่หลุดขึ้น Git
> ครั้งต่อไปแก้อะไรก็ `push.bat "ข้อความ"` พอ

---

## PART 2 — Deploy Server บน NAS_02

SSH เข้า NAS_02 (192.168.0.101):

```bash
cd /volume1/docker
git clone https://github.com/nont-naraphat/helpdesk-agent.git
cd helpdesk-agent

# สร้าง .env จาก template แล้วเติมค่า
cp .env.example .env
nano .env
#   ADMIN_PASSWORD=<รหัสเข้า portal>
#   AGENT_SECRET=<random ยาว ๆ - สร้างด้วย: openssl rand -base64 32>

# build + run
sudo docker compose up -d --build

# เช็ค
sudo docker compose logs -f helpdesk-agent
```

เปิด portal: **http://192.168.0.101:8097**  (login ด้วย ADMIN_PASSWORD)

### เวลาแก้โค้ดแล้ว pull ลงมาใหม่

```bash
cd /volume1/docker/helpdesk-agent
git pull
sudo docker compose up -d --build --force-recreate
```

> ใช้ `--build --force-recreate` เสมอ เพื่อให้โค้ดใหม่เข้า container จริง
> `server/data/` (DB + audit) อยู่ใน volume ไม่หายตอน rebuild

---

## PART 3 — Agent ลง Windows (ผ่าน Intune)

### 3.1 แก้ค่าใน install.ps1 ก่อน package

เปิด `agent/install.ps1` แก้ block บนสุด:

```powershell
$SERVER_URL   = "http://192.168.0.101:8097"      # NAS_02
$AGENT_SECRET = "<ค่าเดียวกับ .env บน NAS_02>"    # ต้องตรงกัน!
$POLL_INTERVAL = 30

$FILE_ALLOWLIST = @(                              # getfile ดึงได้เฉพาะ path พวกนี้
    "C:\ProgramData\SunPassion",
    "C:\ProgramData\BH-IT",
    "C:\Windows\Logs",
    "C:\Windows\Temp",
    "C:\Temp"
)
```

> **สำคัญ:** `AGENT_SECRET` ต้องตรงกับใน `.env` บน NAS_02 ไม่งั้น register ไม่ผ่าน

### 3.2 Package เป็น .intunewin

บนเครื่อง Windows ที่มี [IntuneWinAppUtil.exe](https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool):

```cmd
IntuneWinAppUtil.exe -c .\agent\ -s install.ps1 -o .\output\
```

ได้ไฟล์ `output\install.intunewin`

### 3.3 สร้าง Win32 app ใน Intune

Intune admin center -> Apps -> Windows -> Add -> **Windows app (Win32)** -> upload `install.intunewin`

| ช่อง | ค่า |
|---|---|
| **Install command** | `powershell.exe -ExecutionPolicy Bypass -File install.ps1` |
| **Uninstall command** | `powershell.exe -ExecutionPolicy Bypass -File uninstall.ps1` |
| **Install behavior** | System |
| **Detection rule** | Manually configure -> Registry |
| — Key path | `HKEY_LOCAL_MACHINE\SOFTWARE\SunPassion\HelpdeskAgent` |
| — Value name | `Version` |
| — Detection method | String equals `1.0.0` |

Assign -> เลือกกลุ่มเครื่องเทสต์ก่อน (อย่าเพิ่งยิงทั้ง fleet)

### 3.4 ยืนยันว่าทำงาน

- บนเครื่องเทสต์: Task Scheduler -> เจอ task `SunPassion-HelpdeskAgent` (รันเป็น SYSTEM)
- log ที่ `C:\ProgramData\SunPassion\helpdesk-agent\agent.log`
- ในportal: เครื่องโผล่ในหน้า Devices ภายใน ~30 วิ สถานะเขียว (online)

---

## การใช้งาน portal

1. **Devices** — list เครื่องทั้งหมด + สถานะ online/offline -> คลิกเข้าเครื่อง
2. ในหน้าเครื่อง:
   - **Quick Commands** — กดปุ่มเดียว: System Info / Network / Event Log / Defender /
     Updates / Printers / Processes / Wi-Fi / Group Policy / Ping
   - **File Operations** — List Directory / Read File / Download File
   - **PowerShell Command** — รันคำสั่งอะไรก็ได้
3. ทุกคำสั่ง -> **Confirm modal** -> เข้าคิว -> agent รับไปรัน (ภายใน ~30 วิ) -> ดูผล
4. **Queue** — ดูคำสั่งทั้งหมดทุกเครื่อง filter ตามสถานะ
5. **Audit** — log ทุก action (สร้าง / confirm / download file)

---

## Collectors ทั้งหมด

| ปุ่ม | ดึงอะไร |
|---|---|
| System Info | CPU, RAM, disk, uptime, OS, serial, IP |
| Network | adapter, gateway, DNS, connection ที่เปิดอยู่ |
| Event Log | error/warning 24 ชม.ล่าสุด |
| Defender | สถานะ AV, signature, threat |
| Updates | patch ที่ลง + ที่ค้าง |
| Printers | printer ที่ติดตั้ง |
| Processes | top 30 by CPU |
| Wi-Fi | interface + profiles |
| Group Policy | gpresult |
| Ping | เทสต์ปลายทาง |
| List Directory | list ไฟล์/โฟลเดอร์ |
| Read File | อ่าน text file (<=1 MB) |
| Download File | ดึงไฟล์ (<=20 MB, allowlist เท่านั้น) |
| PowerShell | คำสั่งอะไรก็ได้ |

---

## เรื่อง File Allowlist (อ่านก่อนใช้ Download File)

- `Download File` (getfile) ดึงได้ **เฉพาะไฟล์ใน path ที่อยู่ใน `$FILE_ALLOWLIST`**
- **agent เป็นคนเช็คเอง** — path นอก allowlist โดน refuse ที่เครื่อง ไม่ใช่แค่ซ่อนปุ่ม
- allowlist ว่าง = getfile ปิดสนิท (fail-closed)
- ทุกครั้งที่กด Download server ลง audit: path + size + sha256 + เครื่องไหน + เวลา
- ถ้า incident จริงต้องดึงไฟล์นอก allowlist -> แก้ `$FILE_ALLOWLIST` แล้ว repackage/redeploy
  = เป็น change ที่ตั้งใจและมีร่องรอย (ดีต่อ IPO audit)

`List Directory` และ `Read File` ไม่ติด allowlist (เป็น metadata + text ปกติของงาน
helpdesk) แต่ Read File cap ที่ 1 MB

---

## Troubleshoot

| อาการ | เช็ค |
|---|---|
| เครื่องไม่โผล่ใน portal | `agent.log` -> ดู error register; `AGENT_SECRET` ตรงกันไหม; เครื่องต่อ NAS ได้ไหม |
| register 403 | `AGENT_SECRET` ใน install.ps1 != `.env` บน NAS |
| command ค้าง queued | agent poll ไม่ถึง server / task ไม่รัน -> เช็ค Task Scheduler |
| Download File refuse | path อยู่นอก `$FILE_ALLOWLIST` (ตั้งใจ) |
| Read File error too large | ไฟล์ >1 MB -> ใช้ Download File แทน |

log ฝั่ง agent: `C:\ProgramData\SunPassion\helpdesk-agent\agent.log`
log ฝั่ง server: `sudo docker compose logs -f helpdesk-agent`
audit: หน้า Audit ใน portal หรือ `server/data/audit.log`

---

## หมายเหตุความปลอดภัย (สำหรับ IPO posture)

- Agent รันเป็น **SYSTEM** + มีช่อง PowerShell = เข้าถึงเครื่องได้เต็มที่ในทางเทคนิค
- ควรจำกัดคนที่เข้า portal ได้ (ADMIN_PASSWORD แข็งแรง / ผูก reverse proxy + auth ถ้ามี)
- allowlist ของ getfile เป็น control สำคัญ — เก็บให้แคบ อย่าใส่ user profile / browser path
- ควรมี AUP/policy ภายในว่าเครื่องมือนี้ใช้เพื่ออะไร ใครใช้ได้ ก่อนยิงทั้ง fleet
- audit.log อยู่ใน volume — พิจารณา ship เข้า Wazuh เพื่อทำ append-only จริง

---

**v1.0.0**
