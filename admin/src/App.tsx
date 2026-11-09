import { Navigate, Route, Routes } from 'react-router-dom';
import { useAuth } from './auth';
import { Layout } from './components/Layout';
import { Spinner } from './components/ui';
import { LoginPage } from './pages/Login';
import { DevicesPage } from './pages/Devices';
import { DeviceDetailPage } from './pages/DeviceDetail';
import { GroupsPage } from './pages/Groups';
import { RulesPage } from './pages/Rules';
import { OverridesPage } from './pages/Overrides';
import { UnlockRequestsPage } from './pages/UnlockRequests';
import { SettingsPage } from './pages/Settings';
import { ApiKeysPage } from './pages/ApiKeys';

export function App() {
  const { admin, loading } = useAuth();
  if (loading) return <div className="center"><Spinner /></div>;
  if (!admin) {
    return (
      <Routes>
        <Route path="*" element={<LoginPage />} />
      </Routes>
    );
  }
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<Navigate to="/devices" replace />} />
        <Route path="/devices" element={<DevicesPage />} />
        <Route path="/devices/:id" element={<DeviceDetailPage />} />
        <Route path="/groups" element={<GroupsPage />} />
        <Route path="/rules" element={<RulesPage />} />
        <Route path="/overrides" element={<OverridesPage />} />
        <Route path="/unlock-requests" element={<UnlockRequestsPage />} />
        <Route path="/settings" element={<SettingsPage />} />
        <Route path="/api-keys" element={<ApiKeysPage />} />
        <Route path="*" element={<Navigate to="/devices" replace />} />
      </Route>
    </Routes>
  );
}
