class User {
  final int id;
  final String username;
  final String fullName;
  final String? email;
  final bool isActive;

  const User({
    required this.id,
    required this.username,
    required this.fullName,
    this.email,
    this.isActive = true,
  });

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] as int,
        username: json['username'] as String,
        fullName: json['full_name'] as String? ?? '',
        email: json['email'] as String?,
        isActive: json['is_active'] as bool? ?? true,
      );
}

class AuthResponse {
  final String accessToken;
  final User user;

  const AuthResponse({required this.accessToken, required this.user});

  factory AuthResponse.fromJson(Map<String, dynamic> json) => AuthResponse(
        accessToken: json['access_token'] as String,
        user: User.fromJson(json['user'] as Map<String, dynamic>),
      );
}