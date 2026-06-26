import 'package:flutter/services.dart';
import 'package:flutter_inappwebview_android/flutter_inappwebview_android.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('nullable native context-menu titles do not crash', () async {
    ContextMenuItem? clickedItem;
    var configuredActionCalled = false;
    final contextMenu = ContextMenu(
      menuItems: [
        ContextMenuItem(
          id: 7,
          title: 'Configured item',
          action: () {
            configuredActionCalled = true;
          },
        ),
      ],
      onContextMenuActionItemClicked: (item) {
        clickedItem = item;
      },
    );
    final controller = AndroidInAppWebViewController(
      AndroidInAppWebViewControllerCreationParams(
        id: 1,
        webviewParams: PlatformInAppWebViewWidgetCreationParams(
          contextMenu: contextMenu,
        ),
      ),
    );
    addTearDown(controller.dispose);

    await controller.handler!(
      const MethodCall('onContextMenuActionItemClicked', {
        'id': 99,
        'androidId': 99,
        'iosId': null,
        'title': null,
      }),
    );

    expect(clickedItem, isNotNull);
    expect(clickedItem!.title, isEmpty);
    expect(configuredActionCalled, isFalse);

    await controller.handler!(
      const MethodCall('onContextMenuActionItemClicked', {
        'id': 7,
        'androidId': 7,
        'iosId': null,
        'title': null,
      }),
    );

    expect(clickedItem!.title, 'Configured item');
    expect(configuredActionCalled, isTrue);
  });
}
