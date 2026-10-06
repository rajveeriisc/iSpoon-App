// handedness.dart — which hand is eating, and which weights that implies.
//
// The lift to the mouth is a pitch about the spoon's y axis for either hand;
// the side-to-side (yaw, z) swing is what flips with the hand. So each
// detected bite votes with the sign of its yaw rotation before the mouth, and
// a run of agreeing votes decides. Until then the hand-neutral weights run.

enum Hand { right, left }

/// What the user chose in AI Lab → Model & data.
enum HandPreference { auto, right, left }

/// Which weights / feature mirroring the detector uses right now.
enum HandMode { right, left, neutral }

class HandednessVoter {
  HandednessVoter({
    this.votesToDecide = 3,
    this.preference = HandPreference.auto,
    this.detected,
  });

  final int votesToDecide;
  HandPreference preference;

  /// Hand decided by voting (kept across meals in the profile).
  Hand? detected;

  final List<int> _votes = [];

  HandMode get mode {
    switch (preference) {
      case HandPreference.right:
        return HandMode.right;
      case HandPreference.left:
        return HandMode.left;
      case HandPreference.auto:
        final d = detected;
        if (d == null) return HandMode.neutral;
        return d == Hand.right ? HandMode.right : HandMode.left;
    }
  }

  bool get isVoting => preference == HandPreference.auto && detected == null;

  /// Records one detected bite's yaw rotation before the mouth (deg, positive
  /// = right hand). Returns the hand the moment it is decided, else null.
  Hand? vote(double yawBeforeMouth) {
    if (!isVoting) return null;
    _votes.add(yawBeforeMouth > 0 ? 1 : -1);
    if (_votes.length < votesToDecide) return null;
    final tail = _votes.sublist(_votes.length - votesToDecide);
    final sum = tail.fold<int>(0, (a, b) => a + b);
    if (sum.abs() != votesToDecide) return null;
    detected = tail.last > 0 ? Hand.right : Hand.left;
    _votes.clear();
    return detected;
  }

  /// Forget the decided hand and start voting again.
  void resetDetection() {
    detected = null;
    _votes.clear();
  }
}
