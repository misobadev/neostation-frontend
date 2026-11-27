import 'package:neostation/providers/menu_app_provider.dart';
import 'package:neostation/screens/app_screen.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:neostation/widgets/music_notification_listener.dart';
import 'package:neostation/widgets/romm_upload_notification_listener.dart';
import 'package:neostation/widgets/scraping_notification_listener.dart';

class MainScreen extends StatelessWidget {
  const MainScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: context.read<MenuAppProvider>().scaffoldKey,
      body: ScrapingNotificationListener(
        child: RommUploadNotificationListener(
          child: MusicNotificationListener(child: AppScreen()),
        ),
      ),
    );
  }
}
