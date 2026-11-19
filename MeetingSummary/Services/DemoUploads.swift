#if DEBUG
import UIKit

/// 개발용: 붙여 묻기(D85)의 화면 확인에 쓰는 **가상의** 사진과 PDF. 모두 앱이 그린 것이다 (실제 사진·문서가 아니다).
/// `-demoAttach [one|two|pdf|mix]`로 입력창에 붙여 두고, `-demoAttachSend "말"`이나 `-demoAttachOnly`로 보낸다
@MainActor
enum DemoUploads {
    /// 입력창에 붙일 것들 (바이트와, PDF면 파일 이름)
    static func files(_ demo: String?) -> [(data: Data, name: String?)] {
        switch demo {
        case "two": [(receipt(), nil), (board(), nil)]
        case "pdf": [(pdf(), "가을 워크숍 안내.pdf")]
        case "mix": [(receipt(), nil), (board(), nil), (pdf(), "가을 워크숍 안내.pdf")]
        default: [(receipt(), nil)]
        }
    }

    /// 가짜 맥이 할 말 (가상의 그림에 적힌 가상의 값 그대로)
    nonisolated static func replies(_ demo: String?, textless: Bool) -> [String] {
        let receipt = "아메리카노 2잔 9,000원, 치즈케이크 7,500원, 샌드위치 7,000원"
        let board = "디자인 검토 11월 18일, 테스트 11월 20일, 배포 11월 25일"
        let workshop = "11월 20일 금요일 오후 2시, 3층 대회의실에서 열리고 준비물은 노트북이에요."
        switch demo {
        case "two": return ["영수증은 \(receipt)으로 합계 23,500원이에요.", "화이트보드에는 \(board)이 적혀 있어요."]
        case "pdf": return ["가을 워크숍 안내문이에요. \(workshop)"]
        case "mix": return ["영수증 합계는 23,500원, 화이트보드의 일정은 \(board)이에요.", "PDF는 가을 워크숍 안내문이에요. \(workshop)"]
        default:
            return textless
                ? ["카페 영수증이네요. \(receipt)으로 합계 23,500원이에요.", "무엇을 도와드릴까요?"]
                : ["네, 합계 23,500원이 맞아요.", "\(receipt)을 더한 값이에요."]
        }
    }

    /// 가상의 카페 영수증
    static func receipt() -> Data {
        let size = CGSize(width: 900, height: 1300)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor(red: 0.80, green: 0.74, blue: 0.66, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let paper = CGRect(x: 120, y: 90, width: 660, height: 1120)
            context.cgContext.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: UIColor.black.withAlphaComponent(0.25).cgColor)
            UIColor(white: 0.99, alpha: 1).setFill()
            UIBezierPath(roundedRect: paper, cornerRadius: 6).fill()
            context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

            let ink = UIColor(white: 0.13, alpha: 1)
            func text(_ string: String, _ y: CGFloat, size: CGFloat = 34, weight: UIFont.Weight = .regular, align: NSTextAlignment = .left) {
                let style = NSMutableParagraphStyle()
                style.alignment = align
                (string as NSString).draw(
                    in: CGRect(x: paper.minX + 50, y: y, width: paper.width - 100, height: size * 1.5),
                    withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: size, weight: weight), .foregroundColor: ink, .paragraphStyle: style]
                )
            }
            func row(_ name: String, _ price: String, _ y: CGFloat, weight: UIFont.Weight = .regular, size: CGFloat = 34) {
                text(name, y, size: size, weight: weight)
                text(price, y, size: size, weight: weight, align: .right)
            }
            func rule(_ y: CGFloat) {
                let path = UIBezierPath()
                path.move(to: CGPoint(x: paper.minX + 50, y: y))
                path.addLine(to: CGPoint(x: paper.maxX - 50, y: y))
                path.setLineDash([10, 8], count: 2, phase: 0)
                path.lineWidth = 2
                ink.withAlphaComponent(0.5).setStroke()
                path.stroke()
            }
            text("카페 모카나무", 160, size: 52, weight: .bold, align: .center)
            text("가상 영수증 (화면 확인용)", 240, size: 28, align: .center)
            text("2026-11-15 14:20", 300, size: 28, align: .center)
            rule(380)
            row("아메리카노 x2", "9,000", 420)
            row("치즈케이크", "7,500", 500)
            row("샌드위치", "7,000", 580)
            rule(680)
            row("합계", "23,500원", 720, weight: .bold, size: 44)
            rule(830)
            text("결제: 가상 카드", 870, size: 28)
            text("이용해 주셔서 감사합니다", 1080, size: 28, align: .center)
        }
    }

    /// 가상의 회의실 화이트보드
    static func board() -> Data {
        let size = CGSize(width: 1400, height: 1000)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor(red: 0.36, green: 0.40, blue: 0.44, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let board = CGRect(x: 70, y: 70, width: 1260, height: 860)
            UIColor(white: 0.97, alpha: 1).setFill()
            UIBezierPath(roundedRect: board, cornerRadius: 18).fill()
            UIColor(white: 0.75, alpha: 1).setStroke()
            let frame = UIBezierPath(roundedRect: board, cornerRadius: 18)
            frame.lineWidth = 10
            frame.stroke()

            func text(_ string: String, in rect: CGRect, size: CGFloat, weight: UIFont.Weight, color: UIColor) {
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                (string as NSString).draw(
                    in: rect, withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style]
                )
            }
            text("11월 출시 준비 (가상)", in: CGRect(x: 70, y: 130, width: 1260, height: 90), size: 64, weight: .heavy,
                 color: UIColor(red: 0.10, green: 0.25, blue: 0.60, alpha: 1))
            let notes: [(String, String, UIColor)] = [
                ("디자인 검토", "11/18", UIColor(red: 1.00, green: 0.90, blue: 0.45, alpha: 1)),
                ("테스트", "11/20", UIColor(red: 0.65, green: 0.88, blue: 0.70, alpha: 1)),
                ("배포", "11/25", UIColor(red: 1.00, green: 0.72, blue: 0.70, alpha: 1)),
            ]
            for (index, note) in notes.enumerated() {
                let rect = CGRect(x: 170 + CGFloat(index) * 370, y: 360, width: 320, height: 320)
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: rect.midX, y: rect.midY)
                context.cgContext.rotate(by: [-0.04, 0.03, -0.02][index])
                context.cgContext.translateBy(x: -rect.midX, y: -rect.midY)
                note.2.setFill()
                UIBezierPath(rect: rect).fill()
                text(note.0, in: CGRect(x: rect.minX, y: rect.minY + 80, width: rect.width, height: 70), size: 50, weight: .bold, color: UIColor(white: 0.15, alpha: 1))
                text(note.1, in: CGRect(x: rect.minX, y: rect.minY + 170, width: rect.width, height: 80), size: 64, weight: .heavy, color: UIColor(white: 0.15, alpha: 1))
                context.cgContext.restoreGState()
            }
            text("화면 확인용으로 앱이 그린 그림", in: CGRect(x: 70, y: 800, width: 1260, height: 50), size: 32, weight: .regular, color: UIColor(white: 0.45, alpha: 1))
        }
    }

    /// 가상의 안내문 PDF (2쪽)
    static func pdf() -> Data {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        return UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            func text(_ string: String, _ y: CGFloat, size: CGFloat, weight: UIFont.Weight = .regular) {
                (string as NSString).draw(
                    in: CGRect(x: 60, y: y, width: page.width - 120, height: 200),
                    withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: weight), .foregroundColor: UIColor.black]
                )
            }
            context.beginPage()
            text("가을 워크숍 안내 (가상)", 80, size: 28, weight: .bold)
            text("일시: 2026년 11월 20일 금요일 오후 2시", 160, size: 16)
            text("장소: 3층 대회의실", 190, size: 16)
            text("준비물: 노트북", 220, size: 16)
            text("화면 확인용으로 앱이 만든 문서입니다.", 300, size: 13)
            context.beginPage()
            text("순서", 80, size: 22, weight: .bold)
            text("1. 여는 말\n2. 분기 돌아보기\n3. 조별 토의\n4. 정리", 130, size: 16)
        }
    }
}
#endif
