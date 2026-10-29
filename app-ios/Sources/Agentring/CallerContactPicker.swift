import Contacts
import ContactsUI
import SwiftUI

/// Shares one selected contact property without requesting address-book access.
struct CallerContactPicker: UIViewControllerRepresentable {
    let onSelect: (CallerIdentity) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect, onCancel: onCancel) }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = [CNContactEmailAddressesKey, CNContactPhoneNumbersKey]
        picker.predicateForEnablingContact = NSPredicate(format: "emailAddresses.@count > 0 OR phoneNumbers.@count > 0")
        // Always open the contact so the user chooses the exact matching address.
        picker.predicateForSelectionOfContact = NSPredicate(value: false)
        picker.predicateForSelectionOfProperty = NSPredicate(format: "key IN %@",
            [CNContactEmailAddressesKey, CNContactPhoneNumbersKey])
        return picker
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onSelect: (CallerIdentity) -> Void
        let onCancel: () -> Void

        init(onSelect: @escaping (CallerIdentity) -> Void, onCancel: @escaping () -> Void) {
            self.onSelect = onSelect
            self.onCancel = onCancel
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) { onCancel() }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect property: CNContactProperty) {
            let kind: CallerIdentity.Kind
            let address: String
            if property.key == CNContactEmailAddressesKey, let value = property.value as? String {
                kind = .email; address = value
            } else if property.key == CNContactPhoneNumbersKey, let value = property.value as? CNPhoneNumber {
                kind = .phone; address = value.stringValue
            } else { onCancel(); return }
            let name = CNContactFormatter.string(from: property.contact, style: .fullName) ?? ""
            if let identity = CallerIdentity(kind: kind, address: address, displayName: name,
                                              contactIdentifier: property.contact.identifier) {
                onSelect(identity)
            } else { onCancel() }
        }
    }
}
