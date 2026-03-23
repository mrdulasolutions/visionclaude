import SwiftUI

struct VisionMode: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let icon: String          // SF Symbol name
    let color: String         // hex color (e.g. "#FF6600")
    let systemPrompt: String
    let quickActions: [String] // suggested voice commands
    let isBuiltIn: Bool

    var swiftColor: Color {
        let hex = color.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6,
              let value = UInt64(hex, radix: 16) else {
            return .orange
        }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    static func == (lhs: VisionMode, rhs: VisionMode) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - Built-in Modes

    static let general = VisionMode(
        id: "general",
        name: "General",
        icon: "eye.fill",
        color: "#E87B35",
        systemPrompt: "You are a versatile vision assistant. Describe what you see in the image clearly and concisely. Answer questions about objects, text, scenes, and context visible in the frame. Provide helpful observations and actionable information based on the visual input.",
        quickActions: ["What do you see?", "Read the text", "Describe this scene", "What is this?"],
        isBuiltIn: true
    )

    static let mechanic = VisionMode(
        id: "mechanic",
        name: "Mechanic",
        icon: "wrench.and.screwdriver.fill",
        color: "#3B82F6",
        systemPrompt: "You are an expert automotive mechanic assistant. Identify car parts, read OBD-II diagnostic trouble codes, provide torque specifications, and describe repair procedures. Analyze fluid colors and conditions, assess belt and hose wear, read tire sidewall information (size, speed rating, load index), and identify engine components. Reference manufacturer service manuals and common repair patterns when relevant.",
        quickActions: ["What part is this?", "Read the error code", "What's the torque spec?", "Check this belt"],
        isBuiltIn: true
    )

    static let hvac = VisionMode(
        id: "hvac",
        name: "HVAC",
        icon: "thermometer.medium",
        color: "#EF4444",
        systemPrompt: "You are an expert HVAC technician assistant. Read model and serial number plates to determine equipment age and specifications. Identify refrigerant types, BTU ratings, SEER ratings, and tonnage from nameplates. Diagnose common HVAC issues from visual symptoms, identify correct filter sizes from existing filters or filter slots, assess ductwork condition, and recognize different system types (split, packaged, mini-split, heat pump).",
        quickActions: ["Read the nameplate", "What refrigerant type?", "What filter size?", "Diagnose this unit"],
        isBuiltIn: true
    )

    static let plumber = VisionMode(
        id: "plumber",
        name: "Plumber",
        icon: "drop.fill",
        color: "#06B6D4",
        systemPrompt: "You are an expert plumbing technician assistant. Identify pipe materials (PVC, copper, PEX, galvanized, cast iron) and sizes, recognize fitting types (elbows, tees, couplings, unions), read water heater labels for capacity and energy ratings. Identify valve types (gate, ball, check, PRV), diagnose drain issues from visual clues, and reference plumbing code compliance requirements. Assess water damage and corrosion severity.",
        quickActions: ["What pipe size is this?", "Identify this fitting", "Read the water heater label", "What valve type?"],
        isBuiltIn: true
    )

    static let electrician = VisionMode(
        id: "electrician",
        name: "Electrician",
        icon: "bolt.fill",
        color: "#EAB308",
        systemPrompt: "You are an expert electrician assistant. Read breaker panel labels and identify circuit configurations. Determine wire gauges by color coding and sizing, reference NEC (National Electrical Code) requirements, identify outlet and receptacle types (NEMA configurations), read voltage and amperage from meters and labels, and help with circuit identification and tracing. Flag potential safety hazards and code violations.",
        quickActions: ["Read this panel", "What wire gauge?", "Is this up to code?", "Identify this outlet"],
        isBuiltIn: true
    )

    static let qrScanner = VisionMode(
        id: "qr_scanner",
        name: "QR Scanner",
        icon: "qrcode.viewfinder",
        color: "#22C55E",
        systemPrompt: "You are a QR code and barcode scanning assistant. Automatically detect and decode QR codes, barcodes (EAN-13, EAN-8, UPC, Code 128, Code 39), and 2D codes (PDF417, Aztec, Data Matrix) visible in the image. Process URLs by describing the destination, decode encoded data, extract contact information from vCards, and interpret any structured data embedded in the codes.",
        quickActions: ["Scan this code", "What does this QR say?", "Read the barcode", "Process this URL"],
        isBuiltIn: true
    )

    static let inventory = VisionMode(
        id: "inventory",
        name: "Inventory",
        icon: "shippingbox.fill",
        color: "#A855F7",
        systemPrompt: "You are an inventory management assistant. Count visible items accurately, read product labels including SKU numbers, UPC barcodes, lot numbers, and expiration dates. Track quantities on shelves, identify products by packaging and branding, and organize inventory observations by category. Note any damaged packaging, misplaced items, or stock levels that appear low.",
        quickActions: ["Count these items", "Read the SKU", "What product is this?", "Check stock levels"],
        isBuiltIn: true
    )

    static let safetyInspector = VisionMode(
        id: "safety_inspector",
        name: "Safety",
        icon: "exclamationmark.shield.fill",
        color: "#DC2626",
        systemPrompt: "You are an OSHA safety inspector assistant. Identify workplace hazards including trip hazards, electrical dangers, fall risks, and chemical exposure. Check for proper PPE (Personal Protective Equipment) compliance, verify fire exit signage and accessibility, assess ergonomic risks, and document safety violations with specific location descriptions. Reference applicable OSHA standards and recommend corrective actions.",
        quickActions: ["Check for hazards", "Is PPE correct?", "Inspect fire exits", "Document this violation"],
        isBuiltIn: true
    )

    static let documentReader = VisionMode(
        id: "document_reader",
        name: "Documents",
        icon: "doc.text.viewfinder",
        color: "#6366F1",
        systemPrompt: "You are a document reading and OCR assistant. Extract text from documents, forms, and printed materials with high accuracy. Read business cards and extract contact details (name, title, phone, email, address). Process receipts by itemizing purchases and totals. Interpret forms by identifying fields and their values. Handle handwritten text when legible, and organize extracted data in a structured format.",
        quickActions: ["Read this document", "Extract the text", "Scan this receipt", "Read the business card"],
        isBuiltIn: true
    )

    static let builtInModes: [VisionMode] = [
        general, mechanic, hvac, plumber, electrician, qrScanner, inventory, safetyInspector, documentReader
    ]
}
