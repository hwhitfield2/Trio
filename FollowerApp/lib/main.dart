import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/home_screen.dart';
import 'screens/pair_screen.dart';
import 'state/app_state.dart';
import 'theme/trio_design.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TrioFollowerApp());
}

class TrioFollowerApp extends StatelessWidget {
  const TrioFollowerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState()..initialize(),
      child: MaterialApp(
        title: 'Trio Follower',
        debugShowCheckedModeBanner: false,
        theme: trioThemeData(TrioColors.light, Brightness.light),
        darkTheme: trioThemeData(TrioColors.dark, Brightness.dark),
        // The palette is carried separately from ThemeData because the design
        // names more roles than a ColorScheme has — three inks, three rules,
        // two kinds of danger — and flattening them into the nearest Material
        // slot is how a design system turns back into guesswork.
        builder: (context, child) => TrioTheme(
          colors: Theme.of(context).brightness == Brightness.dark
              ? TrioColors.dark
              : TrioColors.light,
          child: child ?? const SizedBox.shrink(),
        ),
        home: const _Root(),
      ),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final state = context.watch<AppState>();
    if (!state.initialized) {
      return Scaffold(
        backgroundColor: colors.ground,
        body: Center(
          child: SizedBox(
            width: 120,
            height: 2,
            child: LinearProgressIndicator(
              color: colors.accent,
              backgroundColor: colors.hairline,
            ),
          ),
        ),
      );
    }
    return state.isPaired ? const HomeScreen() : const PairScreen();
  }
}
