import Foundation

/// Space for a three-card attention viewport, preserving room for other activity.
enum HUDLayout {
    static func scrollsAttention(count: Int) -> Bool { count > 3 }

    static func activityHeight(maxBodyHeight: CGFloat, heading: CGFloat, footer: CGFloat) -> CGFloat {
        max(0, maxBodyHeight - heading - footer - 36)
    }

    static func attentionHeight(firstThree: [CGFloat], activityBudget: CGFloat, hasOtherSessions: Bool) -> CGFloat {
        let content = firstThree.prefix(3).reduce(0, +) + CGFloat(max(0, min(3, firstThree.count) - 1)) * 8 + 2
        let reserved: CGFloat = hasOtherSessions ? min(180, activityBudget * 0.3) : 0
        return max(60, min(content, 480, activityBudget - reserved - 40))
    }
}
