import UIKit

/// 손끝 반응 (D114). 값이 바뀌는 자리는 `.sensoryFeedback`을 쓰고, 단추를 누른 그 순간처럼 값이 없는 자리는 이것을 부른다.
/// 기기의 "시스템 햅틱"을 끄면 울리지 않는다 (시스템이 정한다)
@MainActor
enum Haptic {
    /// 보내기·단추처럼 가벼운 누름
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    /// 되돌릴 수 없는 일을 정했을 때 (승인·올리기 시작)
    static func firm() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    /// 고르기
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}
