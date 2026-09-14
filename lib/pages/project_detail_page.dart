import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_colors.dart';
import '../services/apply_service.dart';
import '../services/project_service.dart';
import '../services/api_client.dart';
import '../models/responses/api_responses.dart';
import 'proposals_page.dart';
import 'contract_otp_page.dart';
import 'contract_details_page.dart';
import 'design_deliverables_detail_page.dart';
import 'collaboration_workspace_page.dart';
import '../services/contract_service.dart';
import '../services/project_working_service.dart';
import '../services/construction_service.dart';
import '../services/design_service.dart';
import '../services/design_brief_service.dart';
import '../widgets/notifications_sheet.dart';
import '../widgets/location_map_preview.dart';
import 'home_page.dart';
import 'messages_page.dart';
import '../services/post_service.dart';
import 'edit_project_page.dart';
import 'ai_advice_page.dart';
import 'find_designers_page.dart';
import 'find_constructors_page.dart';
import 'site_profile_page.dart';
import 'change_orders_page.dart';
import 'payment_batches_page.dart';
import 'daily_logs_page.dart';
import '../utils/money.dart';

class ProjectDetailPage extends StatefulWidget {
  final String projectId;

  const ProjectDetailPage({super.key, required this.projectId});

  @override
  State<ProjectDetailPage> createState() => _ProjectDetailPageState();
}

class _ProjectDetailPageState extends State<ProjectDetailPage>
    with SingleTickerProviderStateMixin {
  ProjectResponse? _project;
  late final AnimationController _animController;

  /// Applications received per open post, so the owner can see which role is
  /// attracting interest without opening the proposals list. Keyed by post id;
  /// a missing entry means the count hasn't loaded yet.
  Map<String, ({int total, int pending})> _applyStatsByPost = const {};
  List<ProjectWorkingResponse> _projectWorkings = [];
  List<ConstructionItemResponse> _constructionItems = [];
  List<DesignResponse> _designs = [];
  List<ContractResponse> _contracts = [];
  DesignBriefResponse? _brief;
  bool _loading = true;
  String? _error;

  /// A contract awaiting the owner's OTP. Scans every engagement — looking at
  /// only the first missed contracts on the second provider.
  ContractResponse? get _pendingContract {
    for (final c in _contracts) {
      if (c.status.toLowerCase() == 'pending_otp') return c;
    }
    return null;
  }

  /// Who a contract came from. Contracts are fetched per engagement and carry
  /// its id, so the provider is resolved from the engagement list rather than
  /// from the contract's own free-text party info, which the provider may
  /// leave blank. A project can run a designer and a constructor at once, and
  /// "Contract" on its own gives the owner no way to tell them apart.
  String _providerForContract(ContractResponse c) {
    for (final w in _projectWorkings) {
      if (w.id != c.projectWorkingId) continue;
      final name = w.providerDisplayName.isNotEmpty
          ? w.providerDisplayName
          : 'Unnamed provider';
      final role = switch (w.contractType.toLowerCase()) {
        'design' => 'Designer',
        'construction' => 'Constructor',
        'both' => 'Design & Build',
        _ => '',
      };
      return role.isEmpty ? name : '$name · $role';
    }
    return '';
  }

  /// Whether the owner has signed a contract yet, in the owner's own terms.
  /// The raw status ('pending_otp') answers the question in the API's words,
  /// not in words the person being asked to sign would use.
  String _signingStateLabel(ContractResponse c) =>
      switch (c.status.toLowerCase()) {
        'confirmed' => 'Signed',
        'pending_otp' => 'Not signed yet — waiting for your OTP',
        'drafted' => 'Not signed yet — not sent for signing',
        'cancelled' => 'Cancelled',
        final other => other,
      };

  /// Designs still waiting on the owner's approve/revision decision.
  List<DesignResponse> get _designsAwaitingReview => _designs
      .where((d) => const {'pending', 'submitted'}.contains(d.status.toLowerCase()))
      .toList();

  /// Earliest unfinished milestone with a date — the genuine "next" one.
  ConstructionItemResponse? get _nextMilestone {
    final pending = _constructionItems
        .where((i) => i.status.toLowerCase() != 'completed' && i.estimateAt != null)
        .toList()
      ..sort((a, b) => a.estimateAt!.compareTo(b.estimateAt!));
    return pending.isNotEmpty ? pending.first : null;
  }

  /// Most recent work across designs and construction, newest first.
  List<({String title, DateTime at})> get _recentActivity {
    final items = <({String title, DateTime at})>[
      for (final d in _designs)
        (
          title: d.title.isNotEmpty
              ? '${d.title} · ${_designVerb(d.status)}'
              : 'Design ${_designVerb(d.status)}',
          at: d.updatedAt
        ),
      for (final c in _constructionItems)
        (title: '${c.name} · ${_itemVerb(c.status)}', at: c.updatedAt),
    ]..sort((a, b) => b.at.compareTo(a.at));
    return items.take(3).toList();
  }

  static String _designVerb(String status) => switch (status.toLowerCase()) {
        'approved' => 'approved',
        'revision' => 'revision requested',
        'submitted' => 'submitted',
        _ => 'updated',
      };

  static String _itemVerb(String status) => switch (status.toLowerCase()) {
        'completed' => 'completed',
        'in_progress' => 'in progress',
        _ => 'pending',
      };

  String _relativeDay(DateTime dt) {
    final d = DateTime.now().difference(dt);
    if (d.inHours < 1) return 'just now';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays == 1) return 'yesterday';
    if (d.inDays < 7) return '${d.inDays} days ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _loadProject();
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  void _showNotifications() async {
    if (!await ApiClient.isLoggedIn() || !mounted) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => NotificationsSheet(
        onNotificationRead: () {},
      ),
    );
  }

  Future<void> _loadProject() async {
    // Reached from a route popping back into this screen, so the widget may
    // already be gone by the time the future resolves. Every other setState
    // in here is guarded; this one was not.
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        ProjectService.getProject(widget.projectId),
        ProjectWorkingService.getProjectWorkings(projectShopOwnerId: widget.projectId, pageSize: 50),
        // The brief the owner filled in during onboarding. Older projects
        // may not have one, and a failure here shouldn't cost them the page.
        DesignBriefService.getDesignBriefs(projectId: widget.projectId, pageSize: 1)
            .then<Object?>((r) => r)
            .catchError((_) => null),
      ]);
      final briefRes = results[2];
      final brief = briefRes is PaginationResponse<DesignBriefResponse> &&
              briefRes.items.isNotEmpty
          ? briefRes.items.first
          : null;
      final workings = (results[1] as PaginationResponse<ProjectWorkingResponse>).items;

      // Real milestone + activity data lives per-engagement, so gather it in
      // parallel rather than serially.
      final items = <ConstructionItemResponse>[];
      final designs = <DesignResponse>[];
      final contracts = <ContractResponse>[];
      if (workings.isNotEmpty) {
        final fetched = await Future.wait([
          for (final w in workings)
            ConstructionService.getMilestones(projectWorkingId: w.id, pageSize: 50)
                .then<Object?>((r) => r)
                .catchError((_) => null),
          for (final w in workings)
            DesignService.getDesigns(projectWorkingId: w.id, pageSize: 50)
                .then<Object?>((r) => r)
                .catchError((_) => null),
          for (final w in workings)
            ContractService.getContracts(projectWorkingId: w.id, pageSize: 50)
                .then<Object?>((r) => r)
                .catchError((_) => null),
        ]);
        for (final r in fetched) {
          if (r is PaginationResponse<ConstructionItemResponse>) items.addAll(r.items);
          // Unsubmitted provider drafts must not reach the owner's design list
          // or the Pending Approvals count derived from it.
          if (r is PaginationResponse<DesignResponse>) {
            designs.addAll(DesignService.ownerVisible(r.items));
          }
          if (r is PaginationResponse<ContractResponse>) {
            contracts.addAll(ContractService.ownerVisible(r.items));
          }
        }
      }

      // Application counts per open post. Best-effort: a failure here costs a
      // count on a chip, not the page.
      final project = results[0] as ProjectResponse;
      final openPosts =
          project.openPosts.where((p) => p.status.toLowerCase() == 'open').toList();
      final stats = <String, ({int total, int pending})>{};
      if (openPosts.isNotEmpty) {
        final counted = await Future.wait([
          for (final post in openPosts)
            ApplyService.getApplies(postId: post.id, pageSize: 50)
                .then<Object?>((r) => r)
                .catchError((_) => null),
        ]);
        for (var i = 0; i < openPosts.length; i++) {
          final r = counted[i];
          if (r is PaginationResponse<ApplyResponse>) {
            stats[openPosts[i].id] = (
              total: r.totalItems,
              pending: r.items
                  .where((a) => a.status.toLowerCase() == 'pending')
                  .length,
            );
          }
        }
      }

      if (mounted) {
        setState(() {
          _project = project;
          _applyStatsByPost = stats;
          _projectWorkings = workings;
          _constructionItems = items;
          _designs = designs;
          _contracts = contracts;
          _brief = brief;
          _loading = false;
        });
        _animController.forward(from: 0.0);
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Failed to load project';
        });
      }
    }
  }

  // The backend has returned 'inprogress', 'in_progress', and 'active' for
  // the same state at different times — every "is this project active?"
  // check must tolerate all three or it silently dead-ends (e.g. the close
  // project button never rendering for a project whose status came back
  // spelled differently than expected).
  static const _activeStatuses = {'inprogress', 'in_progress', 'active'};

  double _progressFor(ProjectResponse p) {
    final status = p.status.toLowerCase();
    if (status == 'completed') return 1.0;
    if (status == 'draft') return 0.2;
    if (_activeStatuses.contains(status)) return 0.65;
    return 0.4;
  }

  String _statusLabel(String status) {
    if (status.isEmpty) return 'Draft';
    // Backend statuses are snake_case ('in_progress'), so split on the
    // underscore — capitalising the first letter alone leaked "In_progress".
    return status
        .split('_')
        .where((w) => w.isNotEmpty)
        .map((w) => w[0].toUpperCase() + w.substring(1).toLowerCase())
        .join(' ');
  }

  Widget _buildAnimatedSection({required Widget child, required int index}) {
    final double start = (index * 0.08).clamp(0.0, 0.7);
    final double end = (start + 0.4).clamp(0.2, 1.0);

    final CurvedAnimation curved = CurvedAnimation(
      parent: _animController,
      curve: Interval(start, end, curve: Curves.easeOutCubic),
    );

    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final project = _project;

    return Scaffold(
      backgroundColor: const Color(0xFFFBF8F6),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.espresso),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          project?.name ?? 'Project Detail',
          style: GoogleFonts.playfairDisplay(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: AppColors.espresso,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        centerTitle: true,
        actions: [
          if (project != null)
            IconButton(
              tooltip: 'Ask AI about this project',
              icon: const Icon(Icons.psychology_outlined, color: AppColors.espresso),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => AiAdvicePage(project: project)),
              ),
            ),
          if (project != null)
            IconButton(
              icon: const Icon(Icons.edit_outlined, color: AppColors.espresso),
              onPressed: () async {
                final updated = await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => EditProjectPage(project: project)),
                );
                if (updated != null) _loadProject();
              },
            ),
          IconButton(
            icon: const Icon(Icons.notifications_none_rounded, color: AppColors.espresso),
            onPressed: _showNotifications,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.espresso))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(color: AppColors.textSecondary),
                        ),
                        const SizedBox(height: 16),
                        TextButton(onPressed: _loadProject, child: const Text('Retry')),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  color: AppColors.espresso,
                  onRefresh: _loadProject,
                  child: SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 16),
                        _buildAnimatedSection(
                          index: 0,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                project!.name,
                                style: GoogleFonts.playfairDisplay(
                                  fontSize: 28,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.espresso,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                project.address,
                                style: GoogleFonts.inter(
                                  fontSize: 13,
                                  color: AppColors.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '${project.areaM2.toStringAsFixed(0)} m² · ${_statusLabel(project.status)}',
                                style: GoogleFonts.inter(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.placeholder,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        _buildAnimatedSection(
                          index: 1,
                          child: LocationMapPreview(
                            address: project.address,
                            latitude: project.latitude,
                            longitude: project.longitude,
                            showAddress: false,
                          ),
                        ),
                        const SizedBox(height: 24),
                        _buildAnimatedSection(
                          index: 2,
                          child: _buildProgressCard(project),
                        ),
                        const SizedBox(height: 20),
                        _buildAnimatedSection(
                          index: 3,
                          child: _buildBudgetOverview(project),
                        ),
                        const SizedBox(height: 24),
                        if (_brief != null) ...[
                          _buildAnimatedSection(
                            index: 4,
                            child: _buildDesignBrief(_brief!),
                          ),
                          const SizedBox(height: 24),
                        ],
                        if (project.providers.isNotEmpty) ...[
                          _buildAnimatedSection(
                            index: 5,
                            child: Column(
                              children: [
                                _buildNextMilestone(),
                                const SizedBox(height: 20),
                                _buildRecentActivity(),
                                const SizedBox(height: 20),
                                _buildPendingApprovals(),
                                const SizedBox(height: 20),
                                _buildProjectTeam(),
                              ],
                            ),
                          ),
                          const SizedBox(height: 24),
                        ] else if (project.openPosts.isNotEmpty) ...[
                          _buildAnimatedSection(
                            index: 5,
                            child: _buildRecruitingStatus(project.openPosts),
                          ),
                          const SizedBox(height: 24),
                        ] else ...[
                          _buildAnimatedSection(
                            index: 5,
                            child: _buildEmptyProvidersState(),
                          ),
                          const SizedBox(height: 24),
                        ],
                        _buildAnimatedSection(
                          index: 6,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Quick Actions',
                                style: GoogleFonts.playfairDisplay(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: AppColors.espresso,
                                ),
                              ),
                              const SizedBox(height: 16),
                              _buildQuickActions(context),
                            ],
                          ),
                        ),
                        const SizedBox(height: 24),
                        _buildProjectActions(project),
                        const SizedBox(height: 80),
                      ],
                    ),
                  ),
                ),
    );
  }

  Widget _buildProgressCard(ProjectResponse project) {
    final progress = _progressFor(project);
    final percent = (progress * 100).round();

    return Container(
      height: 160,
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        image: const DecorationImage(
          image: NetworkImage('https://images.unsplash.com/photo-1554118811-1e0d58224f24?auto=format&fit=crop&q=80&w=600'),
          fit: BoxFit.cover,
        ),
      ),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.black.withValues(alpha: 0.7)],
          ),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF56642B).withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'Status: ${_statusLabel(project.status)}',
                style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    project.name,
                    style: GoogleFonts.inter(fontSize: 14, color: Colors.white),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '$percent%',
                  style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              height: 4,
              width: double.infinity,
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(2)),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: progress,
                child: Container(decoration: BoxDecoration(color: const Color(0xFFD9EAA3), borderRadius: BorderRadius.circular(2))),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBudgetOverview(ProjectResponse project) {
    final costPerM2 = project.areaM2 > 0 ? (project.budget / project.areaM2) : 0.0;

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: AppColors.espresso.withValues(alpha: 0.05),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
        border: Border.all(
          color: AppColors.espresso.withValues(alpha: 0.06),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: AppColors.espresso.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.account_balance_wallet_rounded,
                      size: 14,
                      color: AppColors.espresso,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'BUDGET OVERVIEW',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.5,
                      color: AppColors.espresso,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF5E0),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFD4E5B3)),
                ),
                child: Text(
                  'Active Plan',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF485623),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Center(
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0.0, end: 1.0),
              duration: const Duration(milliseconds: 1200),
              curve: Curves.easeOutCubic,
              builder: (context, animValue, child) {
                return SizedBox(
                  height: 140,
                  width: 140,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 136,
                        height: 136,
                        child: CircularProgressIndicator(
                          value: animValue,
                          strokeWidth: 12,
                          strokeCap: StrokeCap.round,
                          backgroundColor: AppColors.outlineVariant.withValues(alpha: 0.25),
                          valueColor: const AlwaysStoppedAnimation<Color>(AppColors.espresso),
                        ),
                      ),
                      SizedBox(
                        width: 108,
                        height: 108,
                        child: CircularProgressIndicator(
                          value: animValue * 0.85,
                          strokeWidth: 3,
                          strokeCap: StrokeCap.round,
                          backgroundColor: Colors.transparent,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            const Color(0xFF8C6D46).withValues(alpha: 0.4),
                          ),
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            formatVndCompact(project.budget),
                            style: GoogleFonts.playfairDisplay(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: AppColors.espresso,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Total Budget',
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 28),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFFBF8F6),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.outlineVariant.withValues(alpha: 0.4)),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _buildBudgetStatTile(
                        icon: Icons.payments_outlined,
                        iconBg: AppColors.espresso.withValues(alpha: 0.1),
                        iconColor: AppColors.espresso,
                        label: 'Total Budget',
                        value: formatVnd(project.budget),
                      ),
                    ),
                    Container(
                      height: 36,
                      width: 1,
                      color: AppColors.outlineVariant.withValues(alpha: 0.5),
                    ),
                    Expanded(
                      child: _buildBudgetStatTile(
                        icon: Icons.aspect_ratio_rounded,
                        iconBg: const Color(0xFFEFF5E0),
                        iconColor: const Color(0xFF56642B),
                        label: 'Project Area',
                        value: '${project.areaM2.toStringAsFixed(0)} m²',
                      ),
                    ),
                  ],
                ),
                if (costPerM2 > 0) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 10),
                    child: Divider(height: 1, thickness: 0.8),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.analytics_outlined,
                            size: 15,
                            color: AppColors.textSecondary,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Est. Unit Cost',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                      Text(
                        '~${formatVndCompact(costPerM2)} / m²',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppColors.espresso,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBudgetStatTile({
    required IconData icon,
    required Color iconBg,
    required Color iconColor,
    required String label,
    required String value,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: iconBg,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 16, color: iconColor),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppColors.espresso,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNextMilestone() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.espresso,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'NEXT MILESTONE',
            style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.5, color: Colors.white.withValues(alpha: 0.5)),
          ),
          const SizedBox(height: 16),
          Text(
            _nextMilestone?.name ?? 'No upcoming milestone',
            style: GoogleFonts.playfairDisplay(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.calendar_today_outlined, size: 14, color: Colors.white.withValues(alpha: 0.7)),
              const SizedBox(width: 8),
              Text(
                _nextMilestone?.estimateAt != null
                    ? '${_nextMilestone!.estimateAt!.day}/${_nextMilestone!.estimateAt!.month}/${_nextMilestone!.estimateAt!.year}'
                    : 'Scheduled once construction is planned',
                style: GoogleFonts.inter(fontSize: 12, color: Colors.white.withValues(alpha: 0.7)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActivityItem(String text, String time, Color dotColor, {bool hasLine = true}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(width: 8, height: 8, margin: const EdgeInsets.only(top: 4, bottom: 4), decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle)),
            if (hasLine) Container(width: 1, height: 32, color: AppColors.outlineVariant.withValues(alpha: 0.5)),
          ],
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(text, style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.espresso)),
              const SizedBox(height: 2),
              Text(time, style: GoogleFonts.inter(fontSize: 12, color: AppColors.textSecondary)),
              if (hasLine) const SizedBox(height: 16),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRecentActivity() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Recent Activity', style: GoogleFonts.playfairDisplay(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.espresso)),
              Text('View All', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.placeholder)),
            ],
          ),
          const SizedBox(height: 20),
          if (_recentActivity.isEmpty)
            Text(
              'No activity yet — updates appear here once your providers submit work.',
              style: GoogleFonts.inter(fontSize: 12, color: AppColors.textSecondary, height: 1.5),
            )
          else
            for (final a in _recentActivity)
              _buildActivityItem(a.title, _relativeDay(a.at), const Color(0xFFD9EAA3)),
        ],
      )
    );
  }

  /// The brief the owner answered during onboarding, saved by the API at
  /// project creation. It drove the AI recommendation, and until now there was
  /// no way to read it back — the answers vanished the moment the report closed.
  Widget _buildDesignBrief(DesignBriefResponse brief) {
    final rows = <(String, String)>[
      ('Style', brief.style),
      ('Mood', brief.mood),
      ('Target customer', brief.targetCustomer),
      if ((brief.businessModel ?? '').isNotEmpty)
        ('Business model', brief.businessModel!),
      if (brief.seatCount != null) ('Seats', '${brief.seatCount}'),
      if ((brief.timeline ?? '').isNotEmpty) ('Timeline', brief.timeline!),
    ].where((r) => r.$2.trim().isNotEmpty).toList();

    final notes = <(String, String)>[
      if ((brief.brandNote ?? '').isNotEmpty) ('Brand note', brief.brandNote!),
      if ((brief.businessGoals ?? '').isNotEmpty)
        ('What sets it apart', brief.businessGoals!),
    ];

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.02),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Design Brief',
            style: GoogleFonts.playfairDisplay(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppColors.espresso,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'What you told us when you created this project.',
            style: GoogleFonts.inter(
              fontSize: 11,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 16),
          for (final row in rows) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(
                      row.$1,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      row.$2,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.espresso,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          for (final note in notes) ...[
            const SizedBox(height: 6),
            Text(
              note.$1.toUpperCase(),
              style: GoogleFonts.inter(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
                color: AppColors.outline,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              note.$2,
              style: GoogleFonts.inter(
                fontSize: 12,
                height: 1.5,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPendingApprovals() {
    // Nothing awaiting the owner — don't show an empty panel promising action.
    if (_pendingContract == null && _designsAwaitingReview.isEmpty) {
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Pending Approvals', style: GoogleFonts.playfairDisplay(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.espresso)),
          const SizedBox(height: 16),
          // Both items are driven by data loaded with the project, so they
          // only appear when there is genuinely something to act on.
          if (_pendingContract != null)
            _buildApprovalItem(
              () {
                final from = _providerForContract(_pendingContract!);
                final title = _pendingContract!.title;
                return from.isEmpty
                    ? 'Sign contract: $title'
                    : 'Sign contract from $from: $title';
              }(),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => ContractOtpPage(contract: _pendingContract!),
                  ),
                ).then((_) => _loadProject());
              },
            ),
          if (_pendingContract != null && _designsAwaitingReview.isNotEmpty)
            const SizedBox(height: 8),
          if (_designsAwaitingReview.isNotEmpty)
            _buildApprovalItem(
              _designsAwaitingReview.length == 1
                  ? 'Review design: ${_designsAwaitingReview.first.title}'
                  : 'Review ${_designsAwaitingReview.length} designs',
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => DesignDeliverablesDetailPage(
                      designs: _designsAwaitingReview,
                      onUpdated: _loadProject,
                    ),
                  ),
                ).then((_) => _loadProject());
              },
            ),
        ],
      )
    );
  }
  
  Widget _buildApprovalItem(String text, {VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFF6F3F2),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            // The label carries a contract or design title, so its length is
            // whatever the provider typed — it has to be bounded or it runs
            // straight out of the card.
            Expanded(
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.espresso),
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, size: 16, color: AppColors.placeholder),
          ],
        ),
      ),
    );
  }

  /// Engagements that belong on the Project Team card. The rule lives in
  /// ProjectWorkingService so this and the provider app agree on who counts
  /// as a member.
  ///
  /// Only the display is filtered — `_projectWorkings` still holds every row,
  /// because the slot rules and the project-completion check read it.
  List<ProjectWorkingResponse> get _teamMembers =>
      ProjectWorkingService.visibleTeam(_projectWorkings);

  Widget _buildProjectTeam() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Project Team', style: GoogleFonts.playfairDisplay(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.espresso)),
          const SizedBox(height: 16),
          if (_teamMembers.isEmpty)
            Text('No providers or requests yet.', style: GoogleFonts.inter(fontSize: 13, color: AppColors.textSecondary))
          else
            ..._teamMembers.map((pw) {
              final name = pw.providerDisplayName.isNotEmpty ? pw.providerDisplayName : 'Unknown';
              // E.g. "Designer (Pending)"
              final statusCap = pw.status.isNotEmpty ? (pw.status[0].toUpperCase() + pw.status.substring(1).toLowerCase()) : '';
              final typeCap = pw.contractType.isNotEmpty ? (pw.contractType[0].toUpperCase() + pw.contractType.substring(1).toLowerCase()) : '';
              final roleAndStatus = '$typeCap ${statusCap.isNotEmpty ? '($statusCap)' : ''}'.trim();
              
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _buildTeamMember(
                  name, 
                  roleAndStatus, 
                  'https://ui-avatars.com/api/?name=${Uri.encodeComponent(name)}&background=random&color=fff',
                ),
              );
            }),
          if (_stillRecruiting.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('Recruiting', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5, color: AppColors.outline)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              // Each chip carries its own application count. Accepting a
              // provider swaps the recruiting card out for this one, and the
              // roles still being recruited used to lose their counts in the
              // process — the owner could see "Constructor · open" but not
              // that someone was already waiting on it. The stats are fetched
              // on every load regardless of which card renders, so this only
              // had to start reading them.
              children: _stillRecruiting.map((post) {
                final stats = _applyStatsByPost[post.id];
                final countLabel = stats == null
                    ? null
                    : stats.total == 0
                        ? 'No applications yet'
                        : stats.pending > 0
                            ? '${stats.total} applied · ${stats.pending} to review'
                            : '${stats.total} applied';
                return Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _openProposals,
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: AppColors.primaryFixed.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${_postLabel(post)} · ${post.status}',
                            style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.espresso),
                          ),
                          if (countLabel != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              countLabel,
                              style: GoogleFonts.inter(
                                fontSize: 10,
                                fontWeight: stats!.pending > 0 ? FontWeight.bold : FontWeight.normal,
                                color: stats.pending > 0 ? AppColors.espresso : AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
          // Deliberately outside the `_stillRecruiting` block above, and fed
          // `_openPosts` rather than `_stillRecruiting`. Applications keep
          // arriving on a post whose slot is now filled; the owner still needs
          // to see and decline them. `ProposalsPage` disables Accept per-card
          // with a reason when the slot is gone, so nothing unacceptable can be
          // accepted from here.
          if (_openPosts.isNotEmpty) ...[
            const SizedBox(height: 10),
            Center(
              child: TextButton.icon(
                onPressed: _openProposals,
                icon: const Icon(Icons.how_to_reg_outlined, size: 16, color: AppColors.espresso),
                label: Text('View applications',
                    style: GoogleFonts.inter(
                        fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.espresso)),
              ),
            ),
          ],
          // Posts whose role has since been filled are still live on the
          // marketplace pulling in applications nobody can accept.
          if (_stalePosts.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Still posted but already filled',
                style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5, color: AppColors.outline)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _stalePosts
                  .map((post) => GestureDetector(
                        onTap: () => _closePost(post, stale: true),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF6F3F2),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: AppColors.outlineVariant),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_postLabel(post),
                                  style: GoogleFonts.inter(
                                      fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                              const SizedBox(width: 6),
                              const Icon(Icons.close_rounded, size: 13, color: AppColors.outline),
                            ],
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ],
          const SizedBox(height: 8),
          if (_designTaken && _constructionTaken)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  'Team complete — a designer and a constructor are on this project.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(fontSize: 12, color: AppColors.textSecondary),
                ),
              ),
            )
          else
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                // Hidden once every remaining role already has a listing —
                // inviting a provider directly is still available below.
                if (_hasRoleToPost)
                  TextButton.icon(
                    onPressed: _showRecruitProviderSheet,
                    icon: const Icon(Icons.add_circle_outline, size: 14, color: AppColors.espresso),
                    label: Text('Post Opening', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.espresso)),
                  ),
                TextButton.icon(
                  onPressed: _browseProvidersForProject,
                  icon: const Icon(Icons.person_search_outlined, size: 14, color: AppColors.espresso),
                  label: Text('Find Provider', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.espresso)),
                ),
              ],
            ),
        ],
      ),
    );
  }

  /// A project holds one designer slot and one constructor slot; a 'both'
  /// engagement fills both. The rule itself lives in ProjectWorkingService so
  /// every screen that needs it reads the same definition — see the note there
  /// about keeping it in step with the backend.
  bool _roleTaken(String role) =>
      ProjectWorkingService.roleTaken(_projectWorkings, role);

  bool get _designTaken => _roleTaken('design');
  bool get _constructionTaken => _roleTaken('construction');

  /// True when an open listing already advertises this role. A 'both' listing
  /// asks for one provider covering design and construction, so it counts for
  /// either role on its own.
  bool _roleHasOpenPost(String role) => _openPosts.any((p) {
        final k = p.serviceKind.toLowerCase();
        return k == role || k == 'both';
      });

  /// A role still worth advertising: nobody is engaged for it and no open
  /// listing is already asking for it. Posting a second listing for a role
  /// that already has one just splits the applicants across two queues.
  bool _roleNeedsPost(String role) => !_roleTaken(role) && !_roleHasOpenPost(role);

  /// Whether there is anything left to advertise. Drives the 'Post Opening'
  /// button on both the team card and the recruiting card — a project that
  /// posted for a designer can still need a constructor, and vice versa.
  bool get _hasRoleToPost =>
      _roleNeedsPost('design') || _roleNeedsPost('construction');

  String _postLabel(OpenPostResponse p) {
    final k = p.serviceKind.toLowerCase();
    if (k == 'both') return 'Designer + Constructor';
    if (k == 'design') return 'Designer';
    if (k == 'construction') return 'Constructor';
    return p.serviceKind.isEmpty ? 'Provider' : p.serviceKind;
  }

  /// True when a post is still advertised but the role it asks for is now
  /// filled — so it keeps attracting applications that can't be accepted.
  bool _postIsStale(OpenPostResponse p) {
    if (p.status.toLowerCase() != 'open') return false;
    switch (p.serviceKind.toLowerCase()) {
      case 'both':
        return _designTaken || _constructionTaken;
      case 'design':
        return _designTaken;
      case 'construction':
        return _constructionTaken;
      default:
        return false;
    }
  }

  /// Every post still open, whether or not its role has since been filled.
  ///
  /// Distinct from [_stillRecruiting]: a stale post is one whose slot is taken,
  /// so it shouldn't be advertised as recruiting — but it stays open on the
  /// marketplace and keeps collecting applications, and the owner still needs
  /// to reach those applicants to decline them. Gating "View applications" on
  /// [_stillRecruiting] hid the button exactly when the queue needed clearing.
  List<OpenPostResponse> get _openPosts =>
      (_project?.openPosts ?? const <OpenPostResponse>[])
          .where((p) => p.status.toLowerCase() == 'open')
          .toList();

  List<OpenPostResponse> get _stillRecruiting =>
      _openPosts.where((p) => !_postIsStale(p)).toList();

  List<OpenPostResponse> get _stalePosts =>
      (_project?.openPosts ?? const <OpenPostResponse>[]).where(_postIsStale).toList();

  /// Opens the applications list for every post still open on this project.
  ///
  /// Fed [_openPosts] rather than [_stillRecruiting]: applications keep
  /// arriving on a post whose slot is now filled, and the owner still needs to
  /// reach those applicants to decline them. `ProposalsPage` disables Accept
  /// per card with a reason when the slot has gone.
  void _openProposals() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ProposalsPage(
          openPosts: _openPosts,
          projectId: widget.projectId,
          designTaken: _designTaken,
          constructionTaken: _constructionTaken,
        ),
      ),
    ).then((_) => _loadProject());
  }

  Future<void> _closePost(OpenPostResponse post, {required bool stale}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Close this opening?',
            style: GoogleFonts.playfairDisplay(fontWeight: FontWeight.bold, color: AppColors.espresso)),
        content: Text(
          stale
              ? 'The ${_postLabel(post)} role is already filled. Closing removes the '
                  'listing from the marketplace so you stop receiving applications.\n\n'
                  'Closed listings are not shown here afterwards — if you need this role '
                  'again, post a new opening.'
              : 'This removes the ${_postLabel(post)} listing from the marketplace. '
                  'You can post a new opening later if you still need this role.',
          style: GoogleFonts.inter(fontSize: 13, color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep it')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Close listing',
                style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: AppColors.espresso)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await PostService.updatePost(post.id, UpdatePostRequest(status: 'closed'));
      await _loadProject();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Listing closed')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not close listing: $e')),
        );
      }
    }
  }

  Future<void> _editPostDeadline(OpenPostResponse post) async {
    final initial = post.submissionDeadline ?? DateTime.now().add(const Duration(days: 30));
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isAfter(DateTime.now()) ? initial : DateTime.now().add(const Duration(days: 1)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: const ColorScheme.light(
              primary: AppColors.espresso,
              onPrimary: Colors.white,
              onSurface: AppColors.espresso,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked == null) return;

    final deadline = DateTime(picked.year, picked.month, picked.day, 23, 59, 59);
    if (!deadline.isAfter(DateTime.now())) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Submission deadline must be later than the current time.'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    try {
      await PostService.updatePost(post.id, UpdatePostRequest(submissionDeadline: deadline));
      await _loadProject();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Deadline updated')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update deadline: $e')),
        );
      }
    }
  }

  /// Browse providers with the project already known. Only roles the project
  /// still has an open slot for are offered.
  void _browseProvidersForProject() {
    final project = _project;
    if (project == null) return;

    final needsDesign = !_designTaken;
    final needsConstruction = !_constructionTaken;

    if (!needsDesign && !needsConstruction) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This project already has a designer and a constructor.')),
      );
      return;
    }

    // With only one slot left, pin the engagement to that role so a provider
    // who can do both doesn't silently claim the slot that's already filled.
    final onlyOneSlotLeft = needsDesign != needsConstruction;

    void open(bool constructor) {
      final forcedType = onlyOneSlotLeft ? (constructor ? 'construction' : 'design') : null;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => constructor
              ? FindConstructorsPage(
                  contextProjectId: project.id,
                  contextProjectName: project.name,
                  contextContractType: forcedType,
                )
              : FindDesignersPage(
                  contextProjectId: project.id,
                  contextProjectName: project.name,
                  contextContractType: forcedType,
                ),
        ),
      ).then((_) => _loadProject());
    }

    if (needsDesign && !needsConstruction) return open(false);
    if (needsConstruction && !needsDesign) return open(true);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 20),
            Text(
              'Who are you looking for?',
              style: GoogleFonts.playfairDisplay(fontSize: 18, fontWeight: FontWeight.bold, color: AppColors.espresso),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.architecture_rounded, color: AppColors.espresso),
              title: Text('Designers', style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.espresso)),
              onTap: () {
                Navigator.pop(sheetContext);
                open(false);
              },
            ),
            ListTile(
              leading: const Icon(Icons.handyman_outlined, color: AppColors.espresso),
              title: Text('Constructors', style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.espresso)),
              onTap: () {
                Navigator.pop(sheetContext);
                open(true);
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  void _showRecruitProviderSheet() {
    if (_project == null) return;

    // A role drops off this sheet once it is engaged OR already advertised,
    // so an owner who posted for a designer is offered the constructor slot
    // and not a duplicate designer listing.
    final designOpen = _roleNeedsPost('design');
    final constructionOpen = _roleNeedsPost('construction');
    // 'both' is a single provider covering both roles — only offer it while
    // neither slot is taken.
    final bothOpen = designOpen && constructionOpen;

    if (!designOpen && !constructionOpen) {
      final teamComplete = _designTaken && _constructionTaken;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(teamComplete
              ? 'This project already has a designer and a constructor.'
              : 'Every role this project still needs already has an open listing.'),
        ),
      );
      return;
    }

    String selectedKind = designOpen ? 'design' : 'construction';
    final descriptionController = TextEditingController(
      text: 'Looking for a provider to work on ${_project!.name}.',
    );
    final now = DateTime.now();
    DateTime submissionDeadline = DateTime(now.year, now.month, now.day, 23, 59, 59).add(const Duration(days: 30));
    bool submitting = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            Widget kindOption(String value, String label) {
              final selected = selectedKind == value;
              return Expanded(
                child: GestureDetector(
                  onTap: () => setSheetState(() => selectedKind = value),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: selected ? AppColors.espresso : const Color(0xFFF6F3F2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: selected ? Colors.white : AppColors.espresso,
                      ),
                    ),
                  ),
                ),
              );
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 24,
                bottom: MediaQuery.of(sheetContext).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Recruit a Provider', style: GoogleFonts.playfairDisplay(fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.espresso)),
                  const SizedBox(height: 4),
                  Text(
                    bothOpen
                        ? 'Post an opening so designers and constructors can apply to this project.'
                        : 'Post an opening for the role this project still needs.',
                    style: GoogleFonts.inter(fontSize: 12, color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 20),
                  Text('WHO ARE YOU LOOKING FOR', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5, color: AppColors.outline)),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      if (designOpen) kindOption('design', 'Designer'),
                      if (constructionOpen) kindOption('construction', 'Constructor'),
                      if (bothOpen) kindOption('both', 'Both'),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Text('DESCRIPTION', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5, color: AppColors.outline)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: descriptionController,
                    maxLines: 3,
                    style: GoogleFonts.inter(fontSize: 14, color: AppColors.espresso),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: const Color(0xFFF6F3F2),
                      contentPadding: const EdgeInsets.all(12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text('SUBMISSION DEADLINE', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 0.5, color: AppColors.outline)),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () async {
                      final today = DateTime.now();
                      final todayDateOnly = DateTime(today.year, today.month, today.day);
                      final picked = await showDatePicker(
                        context: sheetContext,
                        initialDate: submissionDeadline,
                        firstDate: todayDateOnly,
                        lastDate: todayDateOnly.add(const Duration(days: 365)),
                        builder: (context, child) {
                          return Theme(
                            data: Theme.of(context).copyWith(
                              colorScheme: const ColorScheme.light(
                                primary: AppColors.espresso,
                                onPrimary: Colors.white,
                                onSurface: AppColors.espresso,
                              ),
                            ),
                            child: child!,
                          );
                        },
                      );
                      if (picked == null) return;
                      // The backend accepts any deadline from today onward (it stores
                      // end-of-day, Vietnam time) — comparing dates rather than exact
                      // instants keeps "today" pickable no matter what time it is here.
                      if (picked.isBefore(todayDateOnly)) {
                        if (sheetContext.mounted) {
                          ScaffoldMessenger.of(sheetContext).showSnackBar(
                            const SnackBar(
                              content: Text('Submission deadline must be today or later.'),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                        return;
                      }
                      final deadline = DateTime(picked.year, picked.month, picked.day, 23, 59, 59);
                      setSheetState(() => submissionDeadline = deadline);
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF6F3F2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.event_outlined, size: 16, color: AppColors.espresso),
                          const SizedBox(width: 8),
                          Text(
                            '${submissionDeadline.day.toString().padLeft(2, '0')}/${submissionDeadline.month.toString().padLeft(2, '0')}/${submissionDeadline.year}',
                            style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.espresso),
                          ),
                          const Spacer(),
                          Text('Tap to change', style: GoogleFonts.inter(fontSize: 11, color: AppColors.placeholder)),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: submitting
                          ? null
                          : () async {
                              final now = DateTime.now();
                              final deadlineDateOnly = DateTime(
                                submissionDeadline.year, submissionDeadline.month, submissionDeadline.day,
                              );
                              if (deadlineDateOnly.isBefore(DateTime(now.year, now.month, now.day))) {
                                ScaffoldMessenger.of(sheetContext).showSnackBar(
                                  const SnackBar(
                                    content: Text('Submission deadline must be today or later.'),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                                return;
                              }
                              setSheetState(() => submitting = true);
                              try {
                                await PostService.createPost(CreatePostRequest(
                                  projectShopOwnerId: _project!.id,
                                  serviceKind: selectedKind,
                                  title: _project!.name,
                                  description: descriptionController.text.trim().isEmpty
                                      ? 'Looking for a provider to work on ${_project!.name}.'
                                      : descriptionController.text.trim(),
                                  submissionDeadline: submissionDeadline,
                                ));
                                if (sheetContext.mounted) Navigator.pop(sheetContext);
                                await _loadProject();
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Opening posted')),
                                  );
                                }
                              } catch (e) {
                                setSheetState(() => submitting = false);
                                if (sheetContext.mounted) {
                                  ScaffoldMessenger.of(sheetContext).showSnackBar(
                                    SnackBar(content: Text('Failed to post opening: $e')),
                                  );
                                }
                              }
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.espresso,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: submitting
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : Text('Post Opening', style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildTeamMember(String name, String role, String avatarUrl) {
    return Row(
      children: [
        CircleAvatar(radius: 16, backgroundImage: NetworkImage(avatarUrl)),
        const SizedBox(width: 12),
        // Provider display names are free text too — same overflow as the
        // approval rows if the column isn't given a bound.
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.espresso)),
              Text(role, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 9, color: AppColors.textSecondary)),
            ],
          ),
        )
      ],
    );
  }

  Future<void> _navigateToWorkspace(
    BuildContext context,
    String targetContractType,
  ) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator(color: AppColors.espresso)),
    );

    try {
      final workings = await ProjectWorkingService.getProjectWorkings(
        projectShopOwnerId: widget.projectId,
        pageSize: 50,
      );
      
      // Callers pass UI wording ('designer'/'constructor'); the backend stores
      // ServiceKind values ('design'/'construction'/'both'). Without this
      // mapping nothing ever matched and we silently fell through to the first
      // engagement — which could be the wrong provider entirely.
      final target = switch (targetContractType.toLowerCase()) {
        'designer' || 'design' => 'design',
        'constructor' || 'construction' => 'construction',
        final other => other,
      };

      // A rejected or terminated engagement is over — opening its workspace
      // would show the work of a provider no longer on the project.
      const live = {'requested', 'accepted', 'completed'};
      final candidates = workings.items
          .where((w) => live.contains(w.status.toLowerCase()))
          .toList();

      ProjectWorkingResponse? matchedWorking;
      for (final w in candidates) {
        final type = w.contractType.toLowerCase();
        // 'both' means one provider covering design and construction.
        if (type == target || type == 'both') {
          matchedWorking = w;
          break;
        }
      }

      if (matchedWorking == null && candidates.isNotEmpty) {
        // Fallback to first available if we are looking for a generic one
        matchedWorking = candidates.first;
      }

      if (matchedWorking == null) {
        // `context` is a parameter here, so the State's `mounted` says nothing
        // about whether *this* context is still usable.
        if (context.mounted) {
          Navigator.pop(context); // close dialog
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No active collaboration found for this project yet.')),
          );
        }
        return;
      }

      if (context.mounted) {
        final workingId = matchedWorking.id;
        Navigator.pop(context); // close dialog
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => CollaborationWorkspacePage(projectWorkingId: workingId),
          ),
        ).then((_) => _loadProject());
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context); // close dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open workspace: $e')),
        );
      }
    }
  }

  Widget _buildQuickActions(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            children: [
              // Approve / Design / Constructor all opened the same
              // project-wide workspace, so they're one action now.
              _buildActionCard(
                Icons.dashboard_customize_outlined,
                'Workspace',
                onTap: () => _navigateToWorkspace(context, 'designer'),
              ),
              const SizedBox(height: 12),
              _buildActionCard(
                Icons.description_outlined,
                'Contract',
                onTap: () => _checkContract(context),
              ),
              const SizedBox(height: 12),
              _buildActionCard(
                Icons.account_balance_wallet_outlined,
                'Payments',
                onTap: () {
                  // Instalments owed under the contract. Reloads on the way
                  // back: submitting proof does not move money, but it does
                  // change what the budget card above reports as settled.
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => PaymentBatchesPage(
                        projectWorkings: _projectWorkings,
                        projectName: _project?.name ?? 'Project',
                      ),
                    ),
                  ).then((_) => _loadProject());
                },
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            children: [
              _buildActionCard(
                Icons.straighten,
                'Site profile',
                onTap: () {
                  // The measured premises. Owner-authored, unlike most of
                  // this screen, which reads what a provider filed.
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => SiteProfilePage(
                        projectShopOwnerId: widget.projectId,
                        projectName: _project?.name ?? 'Project',
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              _buildActionCard(
                Icons.receipt_long_outlined,
                'Change orders',
                onTap: () {
                  // Money agreed after the contract. Reloads on the way
                  // back because approving one moves the committed total
                  // the budget card above shows.
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => ChangeOrdersPage(
                        projectWorkings: _projectWorkings,
                        projectName: _project?.name ?? 'Project',
                      ),
                    ),
                  ).then((_) => _loadProject());
                },
              ),
              const SizedBox(height: 12),
              _buildActionCard(
                Icons.event_note_outlined,
                'Daily log',
                onTap: () {
                  // Read-only: the provider files it from site. No reload on
                  // return — nothing here writes.
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => DailyLogsPage(
                        projectWorkings: _projectWorkings,
                        projectName: _project?.name ?? 'Project',
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              _buildActionCard(
                Icons.forum_outlined,
                'Message',
                onTap: () {
                  // Always let the owner pick the person first — a project can
                  // have a designer and a contractor, and guessing picked one
                  // of them and hid the other.
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => MessagesPage(
                        projectId: widget.projectId,
                        projectName: _project?.name,
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _checkContract(BuildContext context) async {
    if (_projectWorkings.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No project workings found for this project.')));
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator(color: AppColors.espresso)),
    );

    try {
      final allContracts = <ContractResponse>[];
      for (final working in _projectWorkings) {
        // pageSize: 1 silently hid every contract past the first one on an
        // engagement (e.g. a renegotiated/amended contract) from the
        // "Select Contract" picker below.
        final res = await ContractService.getContracts(projectWorkingId: working.id, pageSize: 50);
        allContracts.addAll(ContractService.ownerVisible(res.items));
      }

      if (context.mounted) {
        Navigator.pop(context); // close loading
        if (allContracts.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No active contracts for this project.')));
        } else if (allContracts.length == 1) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => ContractDetailsPage(
                contract: allContracts.first,
                providerName: _providerForContract(allContracts.first),
              ),
            ),
          ).then((_) => _loadProject());
        } else {
          showModalBottomSheet(
            context: context,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
            ),
            builder: (ctx) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text(
                    'Select Contract',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                ),
                ...allContracts.map((c) {
                  final from = _providerForContract(c);
                  return ListTile(
                    leading: const Icon(Icons.description_outlined, color: AppColors.espresso),
                    title: Text(c.title.isNotEmpty ? c.title : 'Untitled contract'),
                    // Which provider drew this one up, and whether it still
                    // needs signing — the two things the picker is for.
                    subtitle: Text(
                      [from, _signingStateLabel(c)]
                          .where((part) => part.isNotEmpty)
                          .join('  ·  '),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              ContractDetailsPage(contract: c, providerName: from),
                        ),
                      ).then((_) => _loadProject());
                    },
                  );
                }),
                const SizedBox(height: 16),
              ],
            ),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context); // close loading
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  
  Widget _buildActionCard(IconData icon, String label, {VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.outlineVariant.withValues(alpha: 0.3)),
        ),
        child: Column(
          children: [
            Icon(icon, color: AppColors.espresso, size: 24),
            const SizedBox(height: 8),
            Text(label, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.bold, color: AppColors.espresso)),
          ],
        ),
      ),
    );
  }

  Future<void> _completeProject() async {
    final engagements = _projectWorkings;
    final conMo = engagements
        .where((e) => ProjectWorkingService.engagedStatuses.contains(e.status.toLowerCase()))
        .toList();
    final daNghiemThu = engagements.where((e) => e.status == "completed").toList();

    if (conMo.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${conMo.length} engagements are still open — accept or cancel them first.')),
      );
      return;
    }

    if (daNghiemThu.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('At least one engagement must be accepted before the project can be closed.')),
      );
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Close project'),
        content: const Text('Are you sure you want to close this project?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.espresso),
            child: const Text('Close project', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await ProjectService.completeProject(widget.projectId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Project completed successfully.')),
        );
        _loadProject();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())), // Backend handles message
        );
      }
    }
  }

  Future<void> _cancelProject() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel Project'),
        content: const Text(
          'Are you sure you want to cancel this project? This will terminate all open collaborations.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Cancel Project', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await ProjectService.cancelProject(widget.projectId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Project cancelled successfully.')),
        );
        _loadProject();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())),
        );
      }
    }
  }

  Widget _buildProjectActions(ProjectResponse project) {
    final status = project.status.toLowerCase();
    final canCancel = status == 'briefed' || _activeStatuses.contains(status);
    final isCompleted = status == 'completed';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_activeStatuses.contains(status)) ...[
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _completeProject,
              icon: const Icon(Icons.verified, size: 20, color: Colors.white),
              label: const Text('Close project'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.espresso,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                textStyle: GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (canCancel) ...[
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _cancelProject,
              icon: const Icon(Icons.cancel, size: 20, color: Colors.red),
              label: const Text('Cancel Project'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red,
                side: const BorderSide(color: Colors.red),
                padding: const EdgeInsets.symmetric(vertical: 16),
                textStyle: GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
        ],
        // Delete is only offered once the project is closed — the backend
        // rejects it otherwise ("cancel or complete before deleting").
        if (isCompleted || project.status.toLowerCase() == 'cancelled') ...[
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _deleteProject,
              icon: const Icon(Icons.delete_outline, size: 20, color: Colors.red),
              label: const Text('Delete project'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red,
                side: const BorderSide(color: Colors.red),
                padding: const EdgeInsets.symmetric(vertical: 16),
                textStyle: GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _deleteProject() async {
    final name = _project?.name ?? 'this project';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete project?',
            style: GoogleFonts.playfairDisplay(fontWeight: FontWeight.bold, color: AppColors.espresso)),
        content: Text(
          'This permanently removes "$name" and its history. This cannot be undone.',
          style: GoogleFonts.inter(fontSize: 13, color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Delete',
                style: GoogleFonts.inter(fontWeight: FontWeight.bold, color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ProjectService.deleteProject(widget.projectId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Project deleted')),
      );
      Navigator.pop(context, true); // back to the list, which reloads
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete: $e')),
        );
      }
    }
  }

  /// How many providers have applied to one listing, and how many of those
  /// still need an answer. Renders nothing until the count has loaded, so an
  /// unanswered request never reads as "0 applications".
  Widget _buildApplyCountChip(OpenPostResponse post) {
    final stats = _applyStatsByPost[post.id];
    if (stats == null) return const SizedBox.shrink();

    final none = stats.total == 0;
    final label = none
        ? 'No applications'
        : stats.pending > 0
            ? '${stats.total} applied · ${stats.pending} to review'
            : '${stats.total} applied';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: none
            ? const Color(0xFFF0EBE6)
            : stats.pending > 0
                ? const Color(0xFFD9EAA3)
                : const Color(0xFFF0EBE6),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: none
              ? AppColors.placeholder
              : stats.pending > 0
                  ? const Color(0xFF56642B)
                  : AppColors.textSecondary,
        ),
      ),
    );
  }

  Widget _buildRecruitingStatus(List<OpenPostResponse> posts) {
    final openPosts = posts.where((p) => p.status.toLowerCase() == 'open').toList();

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.espresso, width: 1.5),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.campaign_outlined, color: AppColors.espresso, size: 18),
              const SizedBox(width: 8),
              Text('FINDING PROVIDERS...', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.5, color: AppColors.espresso)),
            ],
          ),
          const SizedBox(height: 16),
          ...openPosts.map((post) {
            final deadlineStr = post.submissionDeadline != null 
                ? '${post.submissionDeadline!.day}/${post.submissionDeadline!.month}/${post.submissionDeadline!.year}'
                : 'N/A';
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFFBF8F6),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(post.title, style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.bold, color: AppColors.espresso)),
                        ),
                        _buildApplyCountChip(post),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Wrap, not Row: 'DESIGNER + CONSTRUCTOR' next to a full
                    // deadline runs past the card edge on a phone. Letting the
                    // two facts fall onto separate lines keeps them readable
                    // instead of clipping the second one.
                    Wrap(
                      spacing: 16,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.work_outline, size: 12, color: AppColors.textSecondary),
                            const SizedBox(width: 4),
                            Text(_postLabel(post).toUpperCase(), style: GoogleFonts.inter(fontSize: 12, color: AppColors.textSecondary)),
                          ],
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.timer_outlined, size: 12, color: AppColors.textSecondary),
                            const SizedBox(width: 4),
                            Text('Deadline: $deadlineStr', style: GoogleFonts.inter(fontSize: 12, color: AppColors.textSecondary)),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton.icon(
                          onPressed: () => _editPostDeadline(post),
                          icon: const Icon(Icons.edit_calendar_outlined, size: 14, color: AppColors.espresso),
                          label: Text('Edit deadline', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.bold, color: AppColors.espresso)),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                            minimumSize: const Size(0, 32),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: () => _closePost(post, stale: false),
                          icon: const Icon(Icons.close_rounded, size: 14, color: Colors.red),
                          label: Text('Close listing', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.red)),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                            minimumSize: const Size(0, 32),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 8),
          // This card replaces the team card entirely while no provider has
          // been accepted yet, so it has to carry the posting action too —
          // otherwise a project that advertised for a designer had no way
          // left to also advertise for a constructor.
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton.icon(
                onPressed: openPosts.isEmpty
                    ? null
                    : () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ProposalsPage(
                              openPosts: openPosts,
                              projectId: widget.projectId,
                              designTaken: _designTaken,
                              constructionTaken: _constructionTaken,
                            ),
                          ),
                        ).then((_) => _loadProject());
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.espresso,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                  minimumSize: const Size(0, 36),
                ),
                icon: const Icon(Icons.list_alt, size: 14),
                label: Text('View Proposals', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.bold)),
              ),
              if (_hasRoleToPost)
                OutlinedButton.icon(
                  onPressed: _showRecruitProviderSheet,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.espresso,
                    side: const BorderSide(color: AppColors.espresso),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                    minimumSize: const Size(0, 36),
                  ),
                  icon: const Icon(Icons.add_circle_outline, size: 14),
                  label: Text('Post Opening', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.bold)),
                ),
            ],
          )
        ],
      )
    );
  }

  Widget _buildEmptyProvidersState() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.outlineVariant.withValues(alpha: 0.5)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.02), blurRadius: 10, offset: const Offset(0, 2))],
      ),
      child: Center(
        child: Column(
          children: [
            const Icon(Icons.handshake_outlined, size: 32, color: AppColors.placeholder),
            const SizedBox(height: 12),
            Text('No Providers Yet', style: GoogleFonts.playfairDisplay(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.espresso)),
            const SizedBox(height: 8),
            Text(
              'Broadcast your project to marketplace to find designers and constructors.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(fontSize: 12, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (context) => const HomePage(initialIndex: 2)),
                  (route) => false,
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.espresso,
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                minimumSize: const Size(0, 36),
              ),
              child: Text('Find Providers', style: GoogleFonts.inter(fontSize: 11, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }
}

