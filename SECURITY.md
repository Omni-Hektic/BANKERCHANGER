# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.x     | :white_check_mark: |

---

## Reporting a Vulnerability

We take the security and integrity of **BANKERCHANGER** and its decentralized financial infrastructure seriously. If you discover a vulnerability, security flaw, or potential exploit, please report it following our responsible disclosure policy outlined below.

> **DO NOT file public GitHub issues, pull requests, or discussions for security vulnerabilities.**

### Contact Information & Encrypted Reporting

Reports should be delivered directly to the security core:
- **Primary Security Email:** `security@bankerchanger.app`
- **PGP Encryption Key Fingerprint:** `B624 81F9 4DC7 20E5 A9D8  1C04 38E2 75B1 9A0F 416C`
- **Key ID:** `0x9A0F416C`

We strongly recommend encrypting all vulnerability disclosures containing proof-of-concept exploits, transaction traces, or sensitive logs using our public PGP key.

---

## Response & Remediation Service Level Agreements (SLAs)

We commit to the following response and remediation timeline targets for all responsible disclosures:

| Milestone | Target SLA | Details |
| :--- | :--- | :--- |
| **Initial Response & Receipt Confirmation** | **< 24 Hours** | Confirmation of receipt with an assigned case ticket and lead engineer. |
| **Triage & Severity Assessment** | **< 72 Hours** | Validation of reproduction steps, CVSS scoring, and initial impact determination. |
| **Critical Issue Patch Target** | **< 7 Days** | Full patch rollout or contract pause/mitigation for critical vulnerabilities. |
| **Standard / Moderate Fix Target** | **< 21 Days** | Implementation, regression testing, and deployment into staging/production releases. |
| **Public Disclosure & Coordination** | **Mutually Agreed** | Coordinated disclosure window (typically 30–90 days after fix deployment). |

---

## Program Scope: In-Scope vs. Out-of-Scope

### In-Scope Assets & Components
- **Soroban Smart Contracts (`/contracts`)**:
  - Reentrancy, access control bypass, unauthorized liquidity drain, and logic regressions.
  - State corruption, authorization hook failures, and arithmetic flaws.
- **Backend Infrastructure (`/backend`)**:
  - API endpoint authentication and authorization bypasses.
  - Injection attacks (SQL, NoSQL, OS Command, SSRF).
  - Webhook verification timing attacks or signature forged replays.
  - Remote code execution (RCE) and privilege escalation.
- **Key Management & Cryptographic Operations**:
  - Unsafe secret persistence, weak entropy seeds, or transaction signing leakages.

### Out-of-Scope Assets & Practices
- Third-party public Stellar RPC nodes and external Horizon APIs outside the project's control.
- Distributed Denial of Service (DDoS) attacks against public frontend endpoints.
- Social engineering, phishing, or physical attacks targeting contributors or infrastructure operators.
- Vulnerabilities requiring root/jailbroken physical device access with already compromised local operating systems.
- Theoretical issues without demonstrable impact or reproducible proof-of-concept.

---

## Safe Harbor & Ethical Research Guidelines

We consider security research conducted under this policy to be authorized, ethical, and protected under our Safe Harbor principles. We will not pursue civil or criminal action against researchers who comply with the following:

1. **Good Faith & Privacy:** Make a good faith effort to avoid privacy violations, data destruction, service degradation, or interruption of user transactions.
2. **Proportional Demonstration:** Do not exploit vulnerabilities beyond the minimum necessary proof-of-concept to verify exploitability.
3. **No Unauthorized Access:** Do not access, modify, or exfiltrate customer funds, private keys, or personal identifying data without explicit authorization.
4. **Coordinated Disclosure:** Provide reasonable time for our engineering team to remediate and verify the vulnerability before publishing details or exploit code publicly.
5. **Compliance with Laws:** Comply with all applicable local, national, and international laws during testing activities.

Researchers who discover critical vulnerabilities and follow these responsible disclosure procedures are eligible for public recognition, attribution, and program rewards where applicable.
