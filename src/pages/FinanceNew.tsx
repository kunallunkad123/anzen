import { useState } from 'react';
import { Layout } from '../components/Layout';
import { useAuth } from '../contexts/AuthContext';
import {
  DollarSign,
  TrendingUp,
  TrendingDown,
  CreditCard,
  Receipt,
  FileText,
  BarChart3
} from 'lucide-react';

type FinanceTab = 'overview' | 'receivables' | 'payables' | 'banks' | 'expenses' | 'reports';

export function FinanceNew() {
  const { profile } = useAuth();
  const [activeTab, setActiveTab] = useState<FinanceTab>('overview');

  const canManage = profile?.role === 'admin' || profile?.role === 'accounts';

  const tabs: { id: FinanceTab; label: string; icon: any }[] = [
    { id: 'overview', label: 'Overview', icon: BarChart3 },
    { id: 'receivables', label: 'Receivables', icon: TrendingUp },
    { id: 'payables', label: 'Payables', icon: TrendingDown },
    { id: 'banks', label: 'Bank Accounts', icon: CreditCard },
    { id: 'expenses', label: 'Expenses', icon: Receipt },
    { id: 'reports', label: 'Reports', icon: FileText },
  ];

  return (
    <Layout>
      <div className="space-y-6">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-3xl font-bold text-gray-900">Finance Management</h1>
            <p className="text-gray-600 mt-1">
              Comprehensive financial tracking and reporting
            </p>
          </div>
        </div>

        <div className="bg-white rounded-lg shadow">
          <div className="border-b border-gray-200">
            <nav className="flex space-x-8 px-6" aria-label="Tabs">
              {tabs.map((tab) => {
                const Icon = tab.icon;
                return (
                  <button
                    key={tab.id}
                    onClick={() => setActiveTab(tab.id)}
                    className={`
                      flex items-center gap-2 py-4 px-1 border-b-2 font-medium text-sm
                      ${activeTab === tab.id
                        ? 'border-blue-500 text-blue-600'
                        : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300'
                      }
                    `}
                  >
                    <Icon className="w-5 h-5" />
                    {tab.label}
                  </button>
                );
              })}
            </nav>
          </div>

          <div className="p-6">
            {activeTab === 'overview' && <OverviewTab />}
            {activeTab === 'receivables' && <ReceivablesTab canManage={canManage} />}
            {activeTab === 'payables' && <PayablesTab canManage={canManage} />}
            {activeTab === 'banks' && <BankAccountsTab canManage={canManage} />}
            {activeTab === 'expenses' && <ExpensesTab canManage={canManage} />}
            {activeTab === 'reports' && <ReportsTab />}
          </div>
        </div>
      </div>
    </Layout>
  );
}

function OverviewTab() {
  return (
    <div className="space-y-6">
      <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
        <div className="bg-gradient-to-br from-green-500 to-green-600 rounded-lg shadow p-6 text-white">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-sm text-green-100">Total Revenue</p>
              <p className="text-2xl font-bold mt-1">Rp 0</p>
            </div>
            <TrendingUp className="w-8 h-8 text-green-200" />
          </div>
        </div>

        <div className="bg-gradient-to-br from-red-500 to-red-600 rounded-lg shadow p-6 text-white">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-sm text-red-100">Total Expenses</p>
              <p className="text-2xl font-bold mt-1">Rp 0</p>
            </div>
            <TrendingDown className="w-8 h-8 text-red-200" />
          </div>
        </div>

        <div className="bg-gradient-to-br from-blue-500 to-blue-600 rounded-lg shadow p-6 text-white">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-sm text-blue-100">Accounts Receivable</p>
              <p className="text-2xl font-bold mt-1">Rp 0</p>
            </div>
            <Receipt className="w-8 h-8 text-blue-200" />
          </div>
        </div>

        <div className="bg-gradient-to-br from-yellow-500 to-yellow-600 rounded-lg shadow p-6 text-white">
          <div className="flex items-center justify-between">
            <div>
              <p className="text-sm text-yellow-100">Accounts Payable</p>
              <p className="text-2xl font-bold mt-1">Rp 0</p>
            </div>
            <FileText className="w-8 h-8 text-yellow-200" />
          </div>
        </div>
      </div>

      <div className="text-center py-12 text-gray-500">
        <BarChart3 className="w-16 h-16 mx-auto mb-4 text-gray-400" />
        <p className="text-lg font-medium">Financial Overview</p>
        <p className="text-sm mt-2">Select a tab to manage your finances</p>
      </div>
    </div>
  );
}

function ReceivablesTab({ canManage }: { canManage: boolean }) {
  return (
    <div className="text-center py-12 text-gray-500">
      <TrendingUp className="w-16 h-16 mx-auto mb-4 text-gray-400" />
      <p className="text-lg font-medium">Accounts Receivable</p>
      <p className="text-sm mt-2">Track customer payments and outstanding invoices</p>
      <p className="text-xs mt-4 text-gray-400">Feature coming soon...</p>
    </div>
  );
}

function PayablesTab({ canManage }: { canManage: boolean }) {
  return (
    <div className="text-center py-12 text-gray-500">
      <TrendingDown className="w-16 h-16 mx-auto mb-4 text-gray-400" />
      <p className="text-lg font-medium">Accounts Payable</p>
      <p className="text-sm mt-2">Track vendor bills and payments</p>
      <p className="text-xs mt-4 text-gray-400">Feature coming soon...</p>
    </div>
  );
}

function BankAccountsTab({ canManage }: { canManage: boolean }) {
  return (
    <div className="text-center py-12 text-gray-500">
      <CreditCard className="w-16 h-16 mx-auto mb-4 text-gray-400" />
      <p className="text-lg font-medium">Bank Accounts</p>
      <p className="text-sm mt-2">Manage bank accounts and reconciliation</p>
      <p className="text-xs mt-4 text-gray-400">Feature coming soon...</p>
    </div>
  );
}

function ExpensesTab({ canManage }: { canManage: boolean }) {
  return (
    <div className="text-center py-12 text-gray-500">
      <Receipt className="w-16 h-16 mx-auto mb-4 text-gray-400" />
      <p className="text-lg font-medium">Expenses</p>
      <p className="text-sm mt-2">Track operational expenses</p>
      <p className="text-xs mt-4 text-gray-400">Redirecting to current expenses page...</p>
    </div>
  );
}

function ReportsTab() {
  return (
    <div className="text-center py-12 text-gray-500">
      <FileText className="w-16 h-16 mx-auto mb-4 text-gray-400" />
      <p className="text-lg font-medium">Financial Reports</p>
      <p className="text-sm mt-2">Generate P&L, Balance Sheet, and Cash Flow reports</p>
      <p className="text-xs mt-4 text-gray-400">Feature coming soon...</p>
    </div>
  );
}
