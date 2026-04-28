import SwiftUI
import UIKit

struct CalendarDayCell: View {
    let dayNumber: Int
    let image: UIImage?
    let isToday: Bool
    let isCurrentMonth: Bool
    let size: CGFloat
    let ink: Color
    let paper: Color
    let accent: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            cellFill

            VStack(alignment: .leading, spacing: 0) {
                Text("\(dayNumber)")
                    .font(.system(size: dayFontSize, weight: .bold, design: .rounded))
                    .foregroundStyle(dayTextColor)
                    .padding(.top, 8)
                    .padding(.leading, 8)

                Spacer(minLength: 0)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Rectangle())
        .overlay(
            Rectangle()
                .stroke(ink.opacity(isCurrentMonth ? 0.42 : 0.20), lineWidth: 1.3)
        )
        .opacity(isCurrentMonth ? 1 : 0.42)
    }

    private var cellFill: some View {
        ZStack {
            if isToday && image == nil && isCurrentMonth {
                accent
            } else {
                paper.opacity(0.001)
            }

            if let image, isCurrentMonth {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
                    .overlay(
                        Rectangle()
                            .fill(ink.opacity(0.18))
                    )
            }
        }
    }

    private var dayTextColor: Color {
        if isToday && image == nil && isCurrentMonth {
            return Color.white
        }

        if image != nil && isCurrentMonth {
            return .white
        }

        return ink
    }

    private var dayFontSize: CGFloat {
        min(max(size * 0.26, 13), 20)
    }
}

#Preview {
    CalendarDayCell(
        dayNumber: 14,
        image: nil,
        isToday: true,
        isCurrentMonth: true,
        size: 46,
        ink: Color(red: 0.10, green: 0.25, blue: 0.50),
        paper: Color(red: 0.96, green: 0.93, blue: 0.88),
        accent: Color(red: 0.89, green: 0.40, blue: 0.25)
    )
    .padding()
}
