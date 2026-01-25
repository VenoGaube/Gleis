# Klimaticket QR Code - Technical Research & Implementation Guide

## Executive Summary

**Can we generate Klimaticket QR codes?**
- ❌ **Legally valid tickets:** NO - Requires private cryptographic keys from railway operators (criminal offense)
- ✅ **Decode existing tickets:** YES - For legitimate purposes (travel apps, expense tracking)
- ✅ **Mock tickets for development:** YES - But without valid signatures (testing only)

---

## 1. Technical Specifications

### Barcode Format
- **Type:** Aztec Code (2D matrix barcode)
- **Size:** 50×50mm typical
- **Standard:** UIC 918.3 (legacy) / IRS 90918-9 FCB (current)
- **Error Correction:** Minimum 23% + 3 codewords
- **Why Aztec?** Compact, high-density, no quiet zone required, screen-friendly

### Data Structure

```
┌─────────────────────────────────────┐
│ Header (Metadata)                   │
│  - Version identifier               │
│  - Encoding type                    │
├─────────────────────────────────────┤
│ Payload (zlib compressed)           │
│  ┌───────────────────────────────┐  │
│  │ Passenger name                │  │
│  │ Origin / Destination          │  │
│  │ Journey date/time             │  │
│  │ Train details                 │  │
│  │ Company code                  │  │
│  │ Passenger count               │  │
│  │ Price & currency              │  │
│  │ Ticket number                 │  │
│  │ Validation data               │  │
│  └───────────────────────────────┘  │
├─────────────────────────────────────┤
│ Digital Signature                   │
│  - Asymmetric crypto               │
│  - Prevents forgery                │
└─────────────────────────────────────┘
```

### Encoding Details
- **Character Set:** ISO-8859-1
- **Compression:** zlib (DEFLATE algorithm)
- **Modern Format:** ASN.1 with UPER (Unaligned Packed Encoding Rules)
- **Signature:** Public key cryptography (private keys held by ÖBB/railway operators)

---

## 2. Security Architecture

### Digital Signature Process

```
┌──────────────┐
│ Ticket Data  │
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ Hash (SHA)   │ ◄── Fingerprint of data
└──────┬───────┘
       │
       ▼
┌──────────────────────┐
│ Encrypt with         │
│ Private Key (ÖBB)    │ ◄── Only railway operators have this
└──────┬───────────────┘
       │
       ▼
┌──────────────┐
│ Signature    │ ◄── Included in barcode
└──────────────┘

Verification:
┌──────────────┐
│ Public Key   │ ◄── Distributed via UIC PKMW
└──────┬───────┘
       │
       ▼
┌──────────────────────┐
│ Decrypt Signature    │
└──────┬───────────────┘
       │
       ▼
┌──────────────────────┐
│ Compare with Hash    │ ◄── Valid ticket = hashes match
└──────────────────────┘
```

**Key Points:**
- Data is **compressed and signed**, NOT encrypted
- Anyone can read the data, but signatures prevent forgery
- Valid signatures require ÖBB's private key (impossible to obtain legally)

---

## 3. What You CAN Do (Legally)

### ✅ Decode Existing Tickets

**Use Cases:**
- Travel management apps (like KDE Itinerary)
- Expense tracking systems
- Journey planning integrations
- Accessibility features

**Open-Source Libraries:**

**1. TypeScript/Node.js** (Most Popular)
```bash
npm install uic-918-3
```
```typescript
import { decode } from 'uic-918-3';

const ticketData = decode(aztecCodeData);
console.log(ticketData.passenger.name);
console.log(ticketData.journey.origin);
console.log(ticketData.journey.destination);
```

**2. Java** (Official UIC)
```xml
<dependency>
    <groupId>org.uic</groupId>
    <artifactId>UIC-barcode</artifactId>
</dependency>
```

**3. C++** (With Signature Validation)
```bash
# ticket-decoder (opencv, zxing-cpp)
git clone https://github.com/karlheinzkurt/ticket-decoder
```

### ✅ Create Development Mocks

**For Testing Your App:**
```swift
// Mock Aztec code for UI testing (no valid signature)
func generateMockKlimaticketData() -> Data {
    let mockPayload = """
    {
        "passenger": "Max Mustermann",
        "origin": "Wien Hbf",
        "destination": "Salzburg Hbf",
        "validFrom": "2026-01-01",
        "validUntil": "2026-12-31",
        "type": "KlimaTicket Ö"
    }
    """.data(using: .utf8)!

    // Compress with zlib (for format similarity)
    let compressed = try? (mockPayload as NSData).compressed(using: .zlib)

    // Note: This will NOT have a valid signature
    // For visual testing only
    return compressed as? Data ?? Data()
}
```

### ✅ Read Ticket Information

**What Your App Can Do:**
1. **Scan existing Klimaticket** with camera
2. **Decode barcode** to extract journey details
3. **Display ticket info** in a user-friendly way
4. **Set reminders** based on ticket validity
5. **Track expenses** from ticket data
6. **Integration with calendar** for journey dates

**Example Flow:**
```
User scans Klimaticket
    ↓
App decodes Aztec code
    ↓
Extract: Name, Valid dates, Ticket type
    ↓
Store in app for quick access
    ↓
Display digital copy (from actual photo, not generated)
    ↓
Optional: Set calendar reminders for validity expiry
```

---

## 4. What You CANNOT Do (Legally)

### ❌ Generate Valid Tickets

**Why Not:**
- Requires private cryptographic keys from ÖBB
- Keys are stored securely and never shared
- UIC maintains Public Key Management Website (PKMW) for verification keys only

**Legal Consequences (Austria):**
- **Fare evasion:** €55-€138 administrative fine
- **Ticket forgery:** Criminal prosecution (felony)
- **Penalties:** Significant fines, possible imprisonment
- **Record:** Criminal record impact

### ❌ Forge Signatures

**Technical Barriers:**
- 2048-bit or higher RSA/ECDSA keys
- Private keys held in hardware security modules
- No known vulnerabilities
- Signatures verified during ticket inspection

### ❌ Access UIC Specifications

**Restrictions:**
- Full specs available to UIC members only
- Membership requires railway operator status
- Public knowledge from reverse engineering only
- Commercial use requires licensing

---

## 5. Legitimate API Access

### Official Channels

**One Mobility Ticketing GmbH**
- Email: office@one-mobility.at
- Website: https://www.klimaticket.at
- Purpose: Partnership agreements for legitimate integrations

**What You Can Request:**
- API access for ticket validation
- Integration with travel management systems
- Corporate booking solutions
- Accessibility features

**Requirements:**
- Business registration
- Clear use case description
- Legal entity with liability insurance
- Compliance with data protection regulations

---

## 6. Implementation Guide for Gleis App

### Recommended Features

#### ✅ Feature 1: Store Physical Ticket Photos
**Current Implementation:** Already working in your app
```swift
// TicketWalletView.swift - CameraCaptureView
// Takes high-quality photo of Klimaticket
// Stores as PNG for lossless QR code quality
// Perfect for quick access at ticket inspection
```

#### ✅ Feature 2: Add Ticket Decoder (Future)
**What to Add:**
1. Integrate `uic-918-3` library or native Swift decoder
2. Extract ticket info from scanned barcode
3. Display validity dates, passenger name, ticket type
4. Set up expiry reminders

**Benefits:**
- Auto-fill ticket details
- Validity tracking
- Expiry notifications
- Journey history

#### ✅ Feature 3: Smart Reminders
**Based on Decoded Data:**
- Ticket expiry warnings (7 days, 1 day before)
- Renewal reminders
- Integration with your existing journey planning

#### ✅ Feature 4: Quick Access Widget
**Show on Lock Screen:**
- Time until ticket expiry
- Quick access to ticket photo
- One-tap to open full-screen view

---

## 7. Technical Resources

### Open-Source Libraries

| Library | Language | Use Case |
|---------|----------|----------|
| [uic-918-3](https://github.com/justusjonas74/uic-918-3) | TypeScript/Node.js | Decoding UIC tickets |
| [UIC-barcode](https://github.com/UnionInternationalCheminsdeFer/UIC-barcode) | Java | Official FCB implementation |
| [ticket-decoder](https://github.com/karlheinzkurt/ticket-decoder) | C++ | Full pipeline with validation |

### Documentation

- **KDE Itinerary Blog:** https://www.volkerkrause.eu/2019/05/15/kde-itinerary-barcodes.html
- **UIC Barcode Overview:** https://gist.github.com/derhuerst/26c1706c1bc1d9ebae76104a14d27f97
- **ERA Technical Documents:** https://www.era.europa.eu (TAP TSI B.12)

### Standards Documents

- **UIC 918.3** - Legacy standard (MyStandards)
- **IRS 90918-9** - Modern FCB standard (UIC Shop)
- **Regulation (EU) 2021/782** - Rail passengers' rights

---

## 8. Ethical Considerations

### Why Respect the System

**Climate Benefits:**
- Klimaticket promotes public transport over cars
- €1,400/year for unlimited travel is already affordable
- System sustainability requires honest usage

**Infrastructure Investment:**
- Ticket revenue funds:
  - Track maintenance
  - New trains and buses
  - Safety improvements
  - Service expansions
  - Climate initiatives

**Social Contract:**
- Affordable tickets = trust-based system
- Fraud undermines accessibility efforts
- Future pricing depends on revenue stability

---

## 9. Summary & Recommendations

### For Gleis App Development

**✅ DO:**
1. Store high-quality photos of tickets (current implementation is perfect)
2. Consider adding barcode decoding for convenience features
3. Set up validity expiry reminders
4. Integrate with journey planning
5. Provide quick-access widgets

**❌ DON'T:**
1. Generate Klimaticket barcodes
2. Attempt to forge signatures
3. Store or transmit private keys
4. Mislead users about ticket validity
5. Implement any ticket generation features

### Best Practice Implementation

```swift
// Recommended: Ticket Info Helper (read-only)
struct KlimaticketInfo: Codable {
    let scannedDate: Date
    let imageData: Data  // Original photo
    let passengerName: String?  // Decoded if available
    let validFrom: Date?
    let validUntil: Date?
    let ticketType: String?

    // Computed properties
    var isExpiringSoon: Bool {
        guard let validUntil = validUntil else { return false }
        return validUntil.timeIntervalSinceNow < 7 * 24 * 60 * 60
    }

    var daysRemaining: Int? {
        guard let validUntil = validUntil else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: validUntil).day
    }
}
```

---

## 10. Legal Disclaimer

This document is for **educational and research purposes only**. The information provided:

- ✅ Enables legitimate ticket management features
- ✅ Supports legal decoding of personal tickets
- ✅ Promotes understanding of railway technology
- ❌ Does NOT authorize ticket generation
- ❌ Does NOT enable fare evasion
- ❌ Does NOT bypass security measures

**Creating or distributing fake tickets is illegal in Austria and the EU. This guide explicitly discourages such activities.**

---

## Conclusion

Your Gleis app's current implementation of storing high-quality ticket photos is the **right approach**. It's legal, useful, and maintains QR code integrity. Consider adding convenience features like:

1. **Barcode decoding** - Extract validity dates for reminders
2. **Expiry tracking** - Notify users before ticket expires
3. **Quick access** - Lock screen widgets for fast display
4. **Journey integration** - Link ticket to your travel planning

This provides value to users while respecting legal and ethical boundaries.

---

**Questions or need clarification on implementing any of these features?** Let me know!
