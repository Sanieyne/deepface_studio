/// Models representing user-saved cloud generations, moderation outcomes, and library items.

class SavedGeneration {
  final String id;
  final String userId;
  final String mediaType;
  final String storageKey;
  final String prompt;
  final String negativePrompt;
  final String modelId;
  final Map<String, dynamic> settings;
  final int fileSizeBytes;
  final bool isPublic;
  final String moderationStatus;
  final int likesCount;
  final int viewsCount;
  final int reportsCount;
  final DateTime createdAt;
  final DateTime? publishedAt;
  final String? url;

  SavedGeneration({
    required this.id,
    required this.userId,
    required this.mediaType,
    required this.storageKey,
    required this.prompt,
    this.negativePrompt = '',
    required this.modelId,
    this.settings = const {},
    this.fileSizeBytes = 0,
    this.isPublic = false,
    this.moderationStatus = 'approved',
    this.likesCount = 0,
    this.viewsCount = 0,
    this.reportsCount = 0,
    required this.createdAt,
    this.publishedAt,
    this.url,
  });

  String get publicUrl =>
      url ?? 'https://cosmic-gen.com/media/$storageKey';

  String get webGalleryUrl =>
      'https://cosmic-gen.com/gallery/$id';

  factory SavedGeneration.fromJson(Map<String, dynamic> json) {
    return SavedGeneration(
      id: (json['_id'] ?? json['id'] ?? '').toString(),
      userId: (json['userId'] is Map ? json['userId']['_id'] : json['userId'] ?? '').toString(),
      mediaType: json['mediaType'] as String? ?? 'image',
      storageKey: json['storageKey'] as String? ?? '',
      prompt: json['prompt'] as String? ?? '',
      negativePrompt: json['negativePrompt'] as String? ?? '',
      modelId: json['modelId'] as String? ?? 'default',
      settings: json['settings'] is Map ? Map<String, dynamic>.from(json['settings']) : {},
      fileSizeBytes: (json['fileSizeBytes'] as num?)?.toInt() ?? 0,
      isPublic: json['isPublic'] as bool? ?? false,
      moderationStatus: json['moderationStatus'] as String? ?? 'approved',
      likesCount: (json['likesCount'] as num?)?.toInt() ?? 0,
      viewsCount: (json['viewsCount'] as num?)?.toInt() ?? 0,
      reportsCount: (json['reportsCount'] as num?)?.toInt() ?? 0,
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
      publishedAt: json['publishedAt'] != null
          ? DateTime.tryParse(json['publishedAt'].toString())
          : null,
      url: json['url'] as String?,
    );
  }
}

class SaveGenerationResponse {
  final bool success;
  final SavedGeneration? generation;
  final String? message;
  final bool isQuotaExceeded;
  final String? quotaMessage;

  const SaveGenerationResponse({
    required this.success,
    this.generation,
    this.message,
    this.isQuotaExceeded = false,
    this.quotaMessage,
  });
}

class MyGenerationsResponse {
  final bool success;
  final List<SavedGeneration> items;
  final int page;
  final int limit;
  final int total;
  final int totalPages;
  final bool hasMore;

  const MyGenerationsResponse({
    required this.success,
    required this.items,
    this.page = 1,
    this.limit = 20,
    this.total = 0,
    this.totalPages = 1,
    this.hasMore = false,
  });
}

enum PublishVerdict {
  approved,
  pendingReview,
  rejected,
  error,
}

class PublishResult {
  final PublishVerdict verdict;
  final String message;
  final SavedGeneration? generation;

  const PublishResult({
    required this.verdict,
    required this.message,
    this.generation,
  });

  bool get isApproved => verdict == PublishVerdict.approved;
  bool get isPendingReview => verdict == PublishVerdict.pendingReview;
  bool get isRejected => verdict == PublishVerdict.rejected;
}

class CloudUserProfile {
  final String id;
  final String username;
  final String email;
  final String? displayName;
  final String? avatarUrl;
  final String? bio;
  final bool isPublicProfile;
  final double storageQuotaGB;
  final double storageUsedGB;
  final int credits;
  final bool isSubscribed;
  final String subscriptionPlan;
  final String subscriptionTier;
  final String subscriptionStatus;
  final String? gumroadLicenseKey;

  const CloudUserProfile({
    required this.id,
    required this.username,
    required this.email,
    this.displayName,
    this.avatarUrl,
    this.bio,
    this.isPublicProfile = true,
    this.storageQuotaGB = 20.0,
    this.storageUsedGB = 0.0,
    this.credits = 0,
    this.isSubscribed = false,
    this.subscriptionPlan = 'Free Tier',
    this.subscriptionTier = 'free',
    this.subscriptionStatus = 'none',
    this.gumroadLicenseKey,
  });

  bool get isStarter => (subscriptionTier.toLowerCase() == 'starter' || subscriptionPlan.toLowerCase() == 'starter') && isSubscribed;
  bool get isPro => (subscriptionTier.toLowerCase() == 'pro' || subscriptionPlan.toLowerCase() == 'pro') && isSubscribed;
  bool get isVip => (subscriptionTier.toLowerCase() == 'vip' || subscriptionPlan.toLowerCase() == 'vip') && isSubscribed;

  bool get hasCustomProfile =>
      (displayName != null && displayName!.isNotEmpty && displayName != username) ||
      (bio != null && bio!.isNotEmpty) ||
      (avatarUrl != null && avatarUrl!.isNotEmpty);

  factory CloudUserProfile.fromJson(Map<String, dynamic> json) {
    final rawTier = (json['subscriptionTier'] ?? json['tier'] ?? '').toString().toLowerCase();
    final rawStatus = (json['subscriptionStatus'] ?? json['status'] ?? '').toString().toLowerCase();

    final bool isSub = json['isSubscribed'] == true ||
        json['subscribed'] == true ||
        json['role'] == 'admin' ||
        rawStatus == 'active' ||
        rawTier == 'starter' ||
        rawTier == 'pro' ||
        rawTier == 'vip' ||
        (json['subscription'] is Map &&
            (json['subscription']['status'] == 'active' ||
                json['subscription']['active'] == true)) ||
        (json['plan'] != null &&
            json['plan'].toString().toLowerCase() != 'free' &&
            json['plan'].toString().toLowerCase() != 'free tier');

    String tier = rawTier.isNotEmpty ? rawTier : (isSub ? 'pro' : 'free');
    String plan = 'Free Tier';
    if (isSub) {
      if (tier == 'vip' || json['plan']?.toString().toLowerCase() == 'vip') {
        tier = 'vip';
        plan = 'VIP';
      } else if (tier == 'starter' || json['plan']?.toString().toLowerCase() == 'starter') {
        tier = 'starter';
        plan = 'Starter';
      } else {
        tier = 'pro';
        plan = 'Pro';
      }
    }

    return CloudUserProfile(
      id: (json['_id'] ?? json['id'] ?? '').toString(),
      username: json['username'] as String? ?? 'user',
      email: json['email'] as String? ?? '',
      displayName: json['displayName'] as String?,
      avatarUrl: json['avatarUrl'] as String?,
      bio: json['bio'] as String?,
      isPublicProfile: json['isPublicProfile'] as bool? ?? true,
      storageQuotaGB: (json['storageQuotaGB'] as num?)?.toDouble() ?? 20.0,
      storageUsedGB: (json['storageUsedGB'] as num?)?.toDouble() ?? 0.0,
      credits: (json['credits'] as num?)?.toInt() ?? 0,
      isSubscribed: isSub,
      subscriptionPlan: plan,
      subscriptionTier: tier,
      subscriptionStatus: rawStatus.isNotEmpty ? rawStatus : (isSub ? 'active' : 'none'),
      gumroadLicenseKey: json['gumroadLicenseKey'] as String?,
    );
  }
}
