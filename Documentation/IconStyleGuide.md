# SoarX Icon Style Guide

## SF Symbols Usage Standards

This document defines the consistent icon usage across the SoarX app.

### Core Principles

1. **Semantic Consistency**: Icons should convey meaning consistently across the app
2. **Fill vs Outline**: Use fill for active/selected states, outline for inactive
3. **Modern SF Symbols**: All icons are SF Symbols 5.0+ compatible
4. **Semantic Colors**: Icons use meaningful colors (blue=primary, green=positive, red=destructive, orange=warning)

---

## Tab Bar Icons (iOS)

| Tab | Icon | Reasoning |
|-----|------|-----------|
| Discover | `globe` | Discovery, global community |
| Flights | `airplane` | Clear representation of flights |
| Stats | `chart.bar` | Statistical data display |
| Charts | `chart.xyaxis.line` | Advanced analytics graphs |
| Profile | `person.circle` | User profile |

---

## Feature Icons

### Navigation & Maps

| Feature | Icon | State | Color |
|---------|------|-------|-------|
| GPS Track | `point.topleft.down.to.point.bottomright.curvepath.fill` | Filled | Blue |
| Location/Spot | `mappin.circle.fill` | Filled | Orange/Red |
| Map View | `map` | Outline | Blue |
| Expand Map | `arrow.up.left.and.arrow.down.right` | Outline | Secondary |
| Destination | `arrow.right.circle.fill` | Filled | Blue |

### Weather & Flying

| Feature | Icon | State | Color |
|---------|------|-------|-------|
| Wing | `wind` | Outline | Secondary |
| Altitude | `arrow.up` | Outline | Orange |
| Speed | `speedometer` | Outline | Purple |
| Temperature | `thermometer` | Outline | Orange |

### Social Actions

| Feature | Icon (Inactive) | Icon (Active) | Color (Inactive) | Color (Active) |
|---------|----------------|---------------|------------------|----------------|
| Like | `heart` | `heart.fill` | Secondary | Red |
| Bookmark | `bookmark` | `bookmark.fill` | Secondary | Blue |
| Share | `square.and.arrow.up` | - | Secondary | - |
| Follow | `person.badge.plus` | `person.badge.checkmark` | Secondary | Green |

### User & Profile

| Feature | Icon | State | Color |
|---------|------|-------|-------|
| Profile | `person.circle` | Outline | Primary |
| Profile Photo | `person.crop.circle` | Outline | Secondary |
| Add User | `person.crop.circle.badge.plus` | Filled | Green |
| Unknown User | `person.crop.circle.badge.questionmark` | Outline | Secondary |
| Level Badge | `star.fill` | Filled | Gold/Level Color |

### Media

| Feature | Icon | State | Color |
|---------|------|-------|-------|
| Photo | `photo` | Outline | Secondary |
| Photo Badge | `photo.fill` | Filled | Orange |
| Photo Gallery | `photo.on.rectangle.angled` | Outline | Blue |
| Camera | `camera.fill` | Filled | Blue |

### System

| Feature | Icon | State | Color |
|---------|------|-------|-------|
| Settings | `gearshape` | Outline | Secondary |
| Delete | `trash.fill` | Filled | Red |
| Edit | `pencil` | Outline | Blue |
| Save | `checkmark.circle.fill` | Filled | Green |
| Cancel | `xmark.circle.fill` | Filled | Red |
| Info | `info.circle` | Outline | Blue |
| Warning | `exclamationmark.triangle.fill` | Filled | Orange |
| Error | `xmark.circle.fill` | Filled | Red |

---

## Color Semantic Mapping

```swift
// Primary Actions
.blue       // Main brand color, primary actions
.teal       // Secondary accents
.cyan       // Distance, navigation

// Status Colors
.green      // Success, positive, growth
.orange     // Warning, altitude, temperature
.red        // Error, destructive, important
.purple     // Advanced features, speed
.yellow     // Caution, highlights

// Neutral
.primary    // System text color (adapts to dark mode)
.secondary  // Less important text/icons
.tertiary   // De-emphasized content
```

---

## Level Badge Colors

Pilot level badges follow a progression:

- **Level 1-5**: Green (`Color.green`)
- **Level 6-10**: Blue (`Color.blue`)
- **Level 11-20**: Purple (`Color.purple`)
- **Level 21-50**: Orange (`Color.orange`)
- **Level 51+**: Red (`Color.red`)

---

## Implementation Notes

### Consistent Icon Sizes

```swift
// Tab bar icons: System default
.tabItem { Label("Flights", systemImage: "airplane") }

// Caption icons (small badges)
Image(systemName: "photo.fill")
    .font(.caption2)

// Body icons (standard UI elements)
Image(systemName: "heart")
    .font(.subheadline)

// Title icons (headers, emphasis)
Image(systemName: "wind")
    .font(.title3)

// Large display icons (empty states)
Image(systemName: "map")
    .font(.largeTitle)
```

### Accessibility

All icons should:
- Include semantic labels for VoiceOver
- Support Dynamic Type scaling
- Maintain contrast in both light and dark mode
- Use semantic colors that adapt to accessibility settings

### Future Improvements

- [ ] Add custom wing/paraglider icon set (SF Symbols doesn't have paragliding icons)
- [ ] Consider custom badge designs for achievements
- [ ] Explore multicolor SF Symbols for enhanced visual hierarchy

---

## Audit History

**Last Audit**: 2026-01-07
**Audited By**: Claude (Phase 3.4 Implementation)
**Status**: All icons verified to be modern SF Symbols 5.0+ compatible
**Issues Found**: None - icon usage is consistent and modern

**Files Audited**:
- `Views/IOSViews.swift` (Tab bar)
- `Views/DiscoverViews.swift` (Discovery features)
- `Views/FlightsViews.swift` (Flight display)
- `Views/ProfileViews.swift` (User profile)
- `Views/WingsViews.swift` (Wing library)
- `Views/StatsViews.swift` (Statistics)
- `Views/ChartsView.swift` (Analytics)
- `Views/BadgesView.swift` (Gamification)
- `Views/SettingsViews.swift` (Settings)
- All other view files

---

## Migration Checklist (If Needed)

When SF Symbols updates to newer versions:

1. Search for deprecated icon names: `grep -rn "Image(systemName:" Views/*.swift`
2. Check Apple's SF Symbols app for replacements
3. Update this guide with new recommendations
4. Test in both light and dark mode
5. Verify accessibility with VoiceOver

---

*This guide is maintained as part of the SoarX design system.*
