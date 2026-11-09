public typealias OSStatus = Int32
public typealias CFDictionary = [String: Any]
public typealias CFTypeRef = AnyObject
public typealias CFString = String
public let kSecClass: CFString = "class", kSecClassGenericPassword: CFString = "genp", kSecAttrService: CFString = "svce",
    kSecAttrAccount: CFString = "acct", kSecAttrAccessGroup: CFString = "agrp", kSecValueData: CFString = "v_Data",
    kSecAttrAccessible: CFString = "pdmn", kSecAttrAccessibleAfterFirstUnlock: CFString = "ck",
    kSecReturnData: CFString = "r_Data", kSecMatchLimit: CFString = "m_Limit", kSecMatchLimitOne: CFString = "m_LimitOne"
public let errSecSuccess: OSStatus = 0, errSecItemNotFound: OSStatus = -25300
public func SecItemUpdate(_ q: CFDictionary, _ a: CFDictionary) -> OSStatus { 0 }
public func SecItemAdd(_ q: CFDictionary, _ r: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { 0 }
public func SecItemCopyMatching(_ q: CFDictionary, _ r: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { 0 }
public func SecItemDelete(_ q: CFDictionary) -> OSStatus { 0 }
