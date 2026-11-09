import CoreGraphics
import Foundation

/// Squarified treemap layout: tiles whose areas are proportional to their values, kept close to square.
public enum Treemap {
    /// One rectangle per value, in the same order as `values`. Zero or negative values get `.zero`.
    public static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = [CGRect](repeating: .zero, count: values.count)
        let total = values.filter { $0 > 0 }.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let order = values.indices.filter { values[$0] > 0 }.sorted { values[$0] > values[$1] }
        var remaining = rect
        var row: [Int] = []

        func area(_ index: Int) -> Double { values[index] * scale }

        /// The worst aspect ratio in a row laid along a side of length `side`.
        func worst(_ row: [Int], side: Double) -> Double {
            let areas = row.map(area)
            let sum = areas.reduce(0, +)
            guard sum > 0, side > 0, let largest = areas.max(), let smallest = areas.min(), smallest > 0 else { return .infinity }
            return max(side * side * largest / (sum * sum), (sum * sum) / (side * side * smallest))
        }

        func place(_ row: [Int]) {
            let sum = row.map(area).reduce(0, +)
            if remaining.width >= remaining.height {
                // A column along the left edge.
                let width = remaining.height > 0 ? CGFloat(sum) / remaining.height : 0
                var y = remaining.minY
                for index in row {
                    let height = width > 0 ? CGFloat(area(index)) / width : 0
                    result[index] = CGRect(x: remaining.minX, y: y, width: width, height: height)
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY,
                                   width: max(remaining.width - width, 0), height: remaining.height)
            } else {
                // A row along the top edge.
                let height = remaining.width > 0 ? CGFloat(sum) / remaining.width : 0
                var x = remaining.minX
                for index in row {
                    let width = height > 0 ? CGFloat(area(index)) / height : 0
                    result[index] = CGRect(x: x, y: remaining.minY, width: width, height: height)
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height,
                                   width: remaining.width, height: max(remaining.height - height, 0))
            }
        }

        var next = 0
        while next < order.count {
            let index = order[next]
            let side = Double(min(remaining.width, remaining.height))
            if row.isEmpty || worst(row + [index], side: side) <= worst(row, side: side) {
                row.append(index)
                next += 1
            } else {
                place(row)
                row = []
            }
        }
        if !row.isEmpty { place(row) }
        return result
    }
}
