import 'package:flutter/material.dart';

import 'chrome_menu_button.dart';
import 'tabbed_layout.dart';

// Shared metrics for the chat widget cutout and its cards. The cutout draws
// the collapse control and the cards reserve space for it, so both sides must
// use these values.
const double chatWidgetInset = TabbedLayout.cardInset;
const double chatWidgetControlSize = kChromeMenuSize;
const double chatWidgetControlRight = chatWidgetInset;
const double chatWidgetControlsWidth =
    chatWidgetControlRight + chatWidgetControlSize;

final chatWidgetControlStyle = IconButton.styleFrom(
  fixedSize: const Size.square(chatWidgetControlSize),
  minimumSize: Size.zero,
  padding: EdgeInsets.zero,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);
