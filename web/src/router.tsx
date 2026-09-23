import { createBrowserRouter } from 'react-router-dom'
import { ProtectedRoute } from '@/auth/ProtectedRoute'
import OidcCallbackPage from '@/pages/OidcCallbackPage'
import { AuthenticatedShellRoot } from '@/components/layout/AuthenticatedShellRoot'
import ProcessModulesPage from '@/pages/admin/modules/ProcessModulesPage'
import TenantDashboardPage from '@/pages/dashboard/TenantDashboardPage'
import PlatformDashboardPage from '@/pages/dashboard/PlatformDashboardPage'
import DefinitionListPage from '@/pages/definitions/DefinitionListPage'
import DefinitionEditorPage from '@/pages/definitions/DefinitionEditorPage'
import PromotionReviewPage from '@/pages/definitions/PromotionReviewPage'
import DefinitionRollbackPage from '@/pages/definitions/DefinitionRollbackPage'
import InstanceBoardPage from '@/pages/instances/InstanceBoardPage'
import InstanceDetailPage from '@/pages/instances/InstanceDetailPage'
import AttachmentViewerPage from '@/pages/instances/AttachmentViewerPage'
import TaskInboxPage from '@/pages/tasks/TaskInboxPage'
import UsersPage from '@/pages/admin/UsersPage'
import UserDetailPage from '@/pages/admin/UserDetailPage'
import GroupsPage from '@/pages/admin/GroupsPage'
import TokensPage from '@/pages/admin/TokensPage'
import AuditLogPage from '@/pages/admin/AuditLogPage'
import AppearanceSettingsPage from '@/pages/admin/AppearanceSettingsPage'
import HealthDashboardPage from '@/pages/admin/HealthDashboardPage'
import MetricsPage from '@/pages/admin/MetricsPage'
import DlqPage from '@/pages/dlq/DlqPage'
import WebhooksPage from '@/pages/dlq/WebhooksPage'
import RegisterTenantPage from '@/pages/admin/onboarding/RegisterTenantPage'
import OnboardingProgressPage from '@/pages/admin/onboarding/OnboardingProgressPage'
import OnboardingResultPage from '@/pages/admin/onboarding/OnboardingResultPage'
import TenantsPage from '@/pages/admin/tenants/TenantsPage'
import EditTenantPage from '@/pages/admin/tenants/EditTenantPage'
import ServicesPage from '@/pages/admin/services/ServicesPage'
import ExamListPage from '@/pages/exam/ExamListPage'
import ExamSessionPage from '@/pages/exam/ExamSessionPage'
import ExamSessionResultPage from '@/pages/exam/ExamSessionResultPage'
import BilimBagaAdminPage from '@/pages/admin/bilimbaga/BilimBagaAdminPage'
import BilimBagaEntityRoute from '@/pages/admin/bilimbaga/BilimBagaEntityRoute'
import PlatformMigrationConsolePage from '@/pages/admin/platform-migrations/PlatformMigrationConsolePage'
import SolutionPackUpdateLauncherPage from '@/pages/solution-packs/SolutionPackUpdateLauncherPage'
import SolutionPackUpdateReviewPage from '@/pages/solution-packs/SolutionPackUpdateReviewPage'
import EventRetentionPage from '@/pages/admin/event-retention/EventRetentionPage'

export const router = createBrowserRouter([
  {
    path: '/auth/callback',
    element: <OidcCallbackPage />,
  },
  {
    path: '/',
    element: (
      <ProtectedRoute>
        <AuthenticatedShellRoot />
      </ProtectedRoute>
    ),
    children: [
      { index: true, element: <TenantDashboardPage /> },
      { path: 'dashboard', element: <TenantDashboardPage /> },
      { path: 'platform-dashboard', element: <PlatformDashboardPage /> },
      { path: 'definitions', element: <DefinitionListPage /> },
      { path: 'definitions/new', element: <DefinitionEditorPage /> },
      { path: 'definitions/:id', element: <DefinitionEditorPage /> },
      { path: 'definitions/:id/promotions/:reviewId', element: <PromotionReviewPage /> },
      { path: 'definitions/:id/rollback', element: <DefinitionRollbackPage /> },
      { path: 'instances', element: <InstanceBoardPage /> },
      { path: 'instances/:id', element: <InstanceDetailPage /> },
      { path: 'instances/:id/attachments/:attachmentId', element: <AttachmentViewerPage /> },
      { path: 'tasks', element: <TaskInboxPage /> },
      { path: 'admin/users', element: <UsersPage /> },
      { path: 'admin/users/:userId', element: <UserDetailPage /> },
      { path: 'admin/groups', element: <GroupsPage /> },
      { path: 'admin/tokens', element: <TokensPage /> },
      { path: 'admin/audit', element: <AuditLogPage /> },
      { path: 'admin/appearance', element: <AppearanceSettingsPage /> },
      { path: 'admin/health', element: <HealthDashboardPage /> },
      { path: 'admin/metrics', element: <MetricsPage /> },
      { path: 'admin/onboarding', element: <RegisterTenantPage /> },
      { path: 'admin/onboarding/new', element: <RegisterTenantPage /> },
      { path: 'admin/onboarding/:onboardingId/progress', element: <OnboardingProgressPage /> },
      { path: 'admin/onboarding/:onboardingId/result', element: <OnboardingResultPage /> },
      { path: 'admin/tenants', element: <TenantsPage /> },
      { path: 'admin/tenants/:slug/edit', element: <EditTenantPage /> },
      { path: 'admin/services', element: <ServicesPage /> },
      { path: 'admin/modules', element: <ProcessModulesPage /> },
      { path: 'admin/bilimbaga', element: <BilimBagaAdminPage /> },
      { path: 'admin/bilimbaga/:entityType', element: <BilimBagaEntityRoute /> },
      { path: 'admin/platform-migrations', element: <PlatformMigrationConsolePage /> },
      // REQ-381: solution-pack update review screen. `/solution-packs` IS
      // the minimal "company's pack screen" entry point (design §4.1, no
      // real pack inventory exists yet -- OQ-2); the review route is
      // direct-navigation-only (reached via the launcher's
      // navigate(..., { state })), same convention as
      // `definitions/:id/promotions/:reviewId`.
      { path: 'solution-packs', element: <SolutionPackUpdateLauncherPage /> },
      { path: 'solution-packs/:packId/update-review', element: <SolutionPackUpdateReviewPage /> },
      { path: 'admin/event-retention', element: <EventRetentionPage /> },
      { path: 'dlq', element: <DlqPage /> },
      { path: 'webhooks', element: <WebhooksPage /> },
      { path: 'exam', element: <ExamListPage /> },
      { path: 'exam/:examId/session', element: <ExamSessionPage /> },
      // REQ-351: opens an EXISTING session by id (getSessionState only,
      // never startSession). URL is PROVISIONAL -- see
      // ExamSessionResultPage.tsx's own doc comment: REQ-350 may later
      // decide Letflow serves a results-list, in which case this becomes
      // that list's detail view and its URL may be renamed by the
      // requirement that implements the list. Do not depend on this exact
      // spelling as a settled contract.
      { path: 'exam/sessions/:sessionId/result', element: <ExamSessionResultPage /> },
    ],
  },
])
