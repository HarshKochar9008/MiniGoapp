import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The app's single icon set: Lucide outline glyphs at the standard 2px stroke.
///
/// Screens reference these semantic names rather than a glyph directly, so the
/// style stays consistent and a glyph can be swapped in one place. Colour comes
/// from the caller (`context.mini.*`) — icons are ink by default and only take
/// the accent or a state colour when that colour carries meaning.
///
/// The `*Active` variants are the same glyph at a heavier stroke, used for the
/// selected tab in the bottom navigation.
abstract final class MiniIcons {
  // Navigation
  static const IconData home = LucideIcons.house;
  static const IconData homeActive = LucideIcons.house500;
  static const IconData rooms = LucideIcons.users;
  static const IconData roomsActive = LucideIcons.users500;
  static const IconData history = LucideIcons.clock;
  static const IconData historyActive = LucideIcons.clock500;
  static const IconData settings = LucideIcons.settings;
  static const IconData settingsActive = LucideIcons.settings500;
  static const IconData back = LucideIcons.arrowLeft;
  static const IconData chevronRight = LucideIcons.chevronRight;
  static const IconData close = LucideIcons.x;

  // Transfer direction
  static const IconData send = LucideIcons.arrowUpRight;
  static const IconData receive = LucideIcons.arrowDownLeft;
  static const IconData transfer = LucideIcons.arrowLeftRight;
  static const IconData upload = LucideIcons.cloudUpload;
  static const IconData download = LucideIcons.download;
  static const IconData downloaded = LucideIcons.fileCheck;

  // Actions
  static const IconData add = LucideIcons.plus;
  static const IconData edit = LucideIcons.pencil;
  static const IconData copy = LucideIcons.copy;
  static const IconData share = LucideIcons.share2;
  static const IconData shareSheet = LucideIcons.share;
  static const IconData delete = LucideIcons.trash2;
  static const IconData refresh = LucideIcons.refreshCw;
  static const IconData restart = LucideIcons.rotateCcw;
  static const IconData sync = LucideIcons.refreshCcw;
  static const IconData login = LucideIcons.logIn;
  static const IconData addPerson = LucideIcons.userPlus;
  static const IconData pickFile = LucideIcons.fileUp;
  static const IconData play = LucideIcons.circlePlay;

  // QR
  static const IconData qr = LucideIcons.qrCode;
  static const IconData scanQr = LucideIcons.scanQrCode;
  static const IconData scanFrame = LucideIcons.scan;

  // Files
  static const IconData file = LucideIcons.file;
  static const IconData document = LucideIcons.fileText;
  static const IconData image = LucideIcons.image;
  static const IconData video = LucideIcons.film;
  static const IconData audio = LucideIcons.audioLines;
  static const IconData archive = LucideIcons.fileArchive;
  static const IconData code = LucideIcons.code;
  static const IconData inbox = LucideIcons.inbox;

  // Status
  static const IconData success = LucideIcons.circleCheck;
  static const IconData check = LucideIcons.check;
  static const IconData error = LucideIcons.circleAlert;
  static const IconData report = LucideIcons.octagonAlert;
  static const IconData info = LucideIcons.info;
  static const IconData offline = LucideIcons.wifiOff;
  static const IconData cloudOff = LucideIcons.cloudOff;
  static const IconData blocked = LucideIcons.ban;
  static const IconData timer = LucideIcons.timer;
  static const IconData pending = LucideIcons.hourglass;
  static const IconData batterySaver = LucideIcons.batteryLow;
  static const IconData notifications = LucideIcons.bell;

  // Privacy & security
  static const IconData lock = LucideIcons.lock;
  static const IconData unlock = LucideIcons.lockOpen;
  static const IconData shield = LucideIcons.shield;
  static const IconData encrypted = LucideIcons.shieldCheck;
  static const IconData biometric = LucideIcons.fingerprint;

  // Theme
  static const IconData lightMode = LucideIcons.sun;
  static const IconData darkMode = LucideIcons.moon;
  static const IconData systemMode = LucideIcons.sunMoon;
}
