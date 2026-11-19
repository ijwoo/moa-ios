#!/usr/bin/env swift
// 앱 아이콘(1024×1024)을 그린다. TestFlight 업로드에는 아이콘이 반드시 있어야 한다.
// 디자인: 짙은 남색 바탕에 흰 말풍선, 그 안에 체크 표시 — "대화에서 할 일을 뽑는다".
//
// 다시 만들기: swift scripts/make-icon.swift  (리포 루트에서 실행)

import AppKit
import CoreGraphics
import Foundation

let size = 1024
let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appending(path: "MeetingSummary/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
}

guard let ctx = CGContext(data: nil, width: size, height: size,
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("context")
}

// 바탕 (알파 없음 — App Store 아이콘은 투명도를 허용하지 않는다)
ctx.setFillColor(rgb(0x1F3A5F))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

// 말풍선
let bubble = CGRect(x: 192, y: 300, width: 640, height: 470)
ctx.setFillColor(rgb(0xFFFFFF))
ctx.addPath(CGPath(roundedRect: bubble, cornerWidth: 150, cornerHeight: 150, transform: nil))
ctx.fillPath()
// 꼬리
ctx.move(to: CGPoint(x: 330, y: 330))
ctx.addLine(to: CGPoint(x: 270, y: 200))
ctx.addLine(to: CGPoint(x: 450, y: 310))
ctx.closePath()
ctx.fillPath()

// 체크 표시
ctx.setStrokeColor(rgb(0x1F3A5F))
ctx.setLineWidth(70)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 375, y: 540))
ctx.addLine(to: CGPoint(x: 475, y: 440))
ctx.addLine(to: CGPoint(x: 660, y: 630))
ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try rep.representation(using: .png, properties: [:])!.write(to: output)
print("wrote \(output.path)")
