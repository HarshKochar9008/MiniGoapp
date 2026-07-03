import 'package:flutter/material.dart';

/// Global navigator for push / notification deep-links before [MaterialApp] child context exists.
///
/// Mutable (not `final`): a full app reset replaces this with a fresh key so
/// the relaunched [MaterialApp]'s `Navigator` — and everything mounted in its
/// route stack — is torn down and rebuilt, instead of being reparented intact
/// onto the new tree the way a stable `GlobalKey` normally would be.
GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();
