import 'package:ermchat/widgets/panel_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Hosts one overlay sheet in a stack whose height the test drives, the way
/// the Scaffold resize shrinks the chat stack on keyboard ticks.
class _Host extends StatefulWidget {
  const _Host({
    required this.height,
    required this.offstage,
    required this.body,
  });

  final double height;
  final bool offstage;
  final Widget body;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with TickerProviderStateMixin {
  late final PanelManager _panels = PanelManager(
    vsync: this,
    markDirty: () {},
    isMounted: () => mounted,
  );

  @override
  void dispose() {
    _panels.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    hostBuilds++;
    return Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        height: widget.height,
        child: Stack(
          children: [
            _panels.buildOverlaySheet(
              offstage: widget.offstage,
              ratio: _panels.threadSheetRatio,
              header: const SizedBox.shrink(),
              body: widget.body,
              context: context,
            ),
          ],
        ),
      ),
    );
  }
}

int hostBuilds = 0;

void main() {
  testWidgets('a hidden overlay sheet skips layout as the stack shrinks', (
    tester,
  ) async {
    var builds = 0;
    final body = LayoutBuilder(
      builder: (_, _) {
        builds++;
        return const SizedBox.expand();
      },
    );
    Widget host(double height, {bool offstage = true}) => MaterialApp(
      home: _Host(height: height, offstage: offstage, body: body),
    );

    await tester.pumpWidget(host(700));
    final settled = builds;
    for (final h in [650.0, 600.0, 550.0, 500.0]) {
      await tester.pumpWidget(host(h));
    }
    expect(builds, settled);

    // Shown again, it lays out against the live box.
    await tester.pumpWidget(host(500, offstage: false));
    expect(builds, greaterThan(settled));
    final shown = builds;
    await tester.pumpWidget(host(450, offstage: false));
    expect(builds, greaterThan(shown));
  });

  // The host passes its own context to the sheet. Reading padding there
  // subscribed the whole host (HomeScreen) to the keyboard's bottom inset.
  testWidgets('an overlay sheet never ties its host to the bottom inset', (
    tester,
  ) async {
    tester.view.padding = FakeViewPadding(top: 90, bottom: 135);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        home: _Host(height: 700, offstage: true, body: SizedBox.expand()),
      ),
    );
    final settled = hostBuilds;
    for (final bottom in [100.0, 60.0, 20.0, 0.0]) {
      tester.view.padding = FakeViewPadding(top: 90, bottom: bottom);
      await tester.pump();
    }
    expect(hostBuilds, settled);
  });
}
