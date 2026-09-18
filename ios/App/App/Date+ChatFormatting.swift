import Foundation

extension Date {
    var chatListTimeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(self) ? "HH:mm" : "MM/dd"
        return formatter.string(from: self)
    }

    var messageTimeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: self)
    }
}
