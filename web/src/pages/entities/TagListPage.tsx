/** TagListPage — REQ-336
 *
 *  The pilot instantiation of the generic admin-CRUD screen engine, against
 *  the `tag` entity type (REQ-326's tag.json: one field, `name`, :string,
 *  required, unique — no foreign keys). List + create + edit + delete, all
 *  built against the REAL route surface (see web/src/api/entities.ts's own
 *  moduledoc-style comment): records are read exclusively via
 *  `POST /entities/query`, cursor-paginated (never a client-side slice of
 *  one page — `cursorStack`/`goNext`/`goPrev` below mirrors
 *  `web/src/pages/dlq/DlqPage.tsx`'s own REQ-277 cursor-stack-to-page
 *  adaptation, the established pattern in this codebase for
 *  `PaginationControls` over a cursor API).
 */

import { useMemo, useState } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useIntl } from 'react-intl'
import { entitiesApi } from '@/api/entities'
import { queryKeys } from '@/api/queryKeys'
import type { ApiError, EntityRecord } from '@/types/api'
import { PageLayout } from '@/components/ui/PageLayout'
import { Button } from '@/components/ui/Button'
import { DataTable, type DataTableColumn } from '@/components/ui/DataTable'
import { PaginationControls } from '@/components/ui/PaginationControls'
import { ConfirmDialog } from '@/components/ui/ConfirmDialog'
import { QueryStateBoundary } from '@/components/ui/QueryStateBoundary'
import { classifyError, type RendererState } from '@/utils/classifyError'
import { EntityRecordForm } from '@/components/entities/EntityRecordForm'
import { EntitiesIntlProvider } from '@/i18n/EntitiesIntlProvider'

const ENTITY_TYPE = 'tag'
const PAGE_SIZE = 25

type ModalState = { kind: 'create' } | { kind: 'edit'; record: EntityRecord } | null

function isApiError(err: unknown): err is ApiError {
  return typeof err === 'object' && err !== null && 'status' in err
}

function TagListPageInner() {
  const intl = useIntl()
  const qc = useQueryClient()

  const [cursorStack, setCursorStack] = useState<string[]>([])
  const [modal, setModal] = useState<ModalState>(null)
  const [deleteTarget, setDeleteTarget] = useState<EntityRecord | null>(null)
  const [formError, setFormError] = useState<ApiError | null>(null)
  const [deleteError, setDeleteError] = useState<string | null>(null)

  const cursor = cursorStack.length > 0 ? cursorStack[cursorStack.length - 1] : undefined

  const definitionQuery = useQuery({
    queryKey: queryKeys.entities.definition(ENTITY_TYPE),
    queryFn: () => entitiesApi.getActiveDefinition(ENTITY_TYPE),
  })

  const recordsQuery = useQuery({
    queryKey: queryKeys.entities.records(ENTITY_TYPE, { cursor, page_size: PAGE_SIZE }),
    queryFn: () => entitiesApi.queryRecords(ENTITY_TYPE, { cursor, page_size: PAGE_SIZE }),
  })

  const rows = useMemo(() => recordsQuery.data?.items ?? [], [recordsQuery.data])

  const invalidateList = () => {
    void qc.invalidateQueries({ queryKey: queryKeys.entities.all })
  }

  const createMutation = useMutation({
    mutationFn: (fieldValues: Record<string, unknown>) => entitiesApi.createRecord(ENTITY_TYPE, fieldValues),
    onSuccess: () => {
      setModal(null)
      setFormError(null)
      invalidateList()
    },
    onError: (err: unknown) => {
      setFormError(isApiError(err) ? err : null)
    },
  })

  const updateMutation = useMutation({
    mutationFn: ({ recordId, fieldValues, ifMatch }: { recordId: string; fieldValues: Record<string, unknown>; ifMatch?: string }) =>
      entitiesApi.updateRecord(ENTITY_TYPE, recordId, fieldValues, ifMatch),
    onSuccess: () => {
      setModal(null)
      setFormError(null)
      invalidateList()
    },
    onError: (err: unknown) => {
      setFormError(isApiError(err) ? err : null)
    },
  })

  const deleteMutation = useMutation({
    mutationFn: (recordId: string) => entitiesApi.deleteRecord(ENTITY_TYPE, recordId),
    onSuccess: () => {
      setDeleteTarget(null)
      setDeleteError(null)
      invalidateList()
    },
    onError: () => {
      setDeleteError(intl.formatMessage({ id: 'entities.tag.delete.error' }))
    },
  })

  const goNext = () => {
    if (!recordsQuery.data?.next_cursor) return
    setCursorStack((prev) => [...prev, recordsQuery.data!.next_cursor as string])
  }
  const goPrev = () => setCursorStack((prev) => prev.slice(0, -1))
  const page = cursorStack.length + 1
  const hasNextPage = recordsQuery.data?.next_cursor != null

  const openCreate = () => {
    setFormError(null)
    setModal({ kind: 'create' })
  }
  const openEdit = (record: EntityRecord) => {
    setFormError(null)
    setModal({ kind: 'edit', record })
  }
  const closeModal = () => {
    setModal(null)
    setFormError(null)
  }

  const handleSubmit = (fieldValues: Record<string, unknown>) => {
    if (modal?.kind === 'create') {
      createMutation.mutate(fieldValues)
    } else if (modal?.kind === 'edit') {
      updateMutation.mutate({
        recordId: modal.record.record_id,
        fieldValues,
        ifMatch: modal.record.entity_def_version,
      })
    }
  }

  const confirmDelete = () => {
    if (!deleteTarget) return
    deleteMutation.mutate(deleteTarget.record_id)
  }

  const columns: DataTableColumn<EntityRecord>[] = [
    {
      id: 'name',
      header: intl.formatMessage({ id: 'entities.tag.list.column.name' }),
      accessor: (row) => String(row.field_values.name ?? ''),
      sortable: true,
      sortValue: (row) => String(row.field_values.name ?? ''),
    },
    {
      id: 'actions',
      header: intl.formatMessage({ id: 'entities.tag.list.column.actions' }),
      accessor: (row) => (
        <div style={{ display: 'flex', gap: '.4rem' }} onClick={(e) => e.stopPropagation()}>
          <Button variant="secondary" size="sm" data-testid={`tag-edit-${row.record_id}`} onClick={() => openEdit(row)}>
            {intl.formatMessage({ id: 'entities.tag.list.editAction' })}
          </Button>
          <Button
            variant="danger"
            size="sm"
            data-testid={`tag-delete-${row.record_id}`}
            onClick={() => setDeleteTarget(row)}
          >
            {intl.formatMessage({ id: 'entities.tag.list.deleteAction' })}
          </Button>
        </div>
      ),
    },
  ]

  const definition = definitionQuery.data

  return (
    <div data-testid="tag-list-page">
      <PageLayout
        title={intl.formatMessage({ id: 'entities.tag.list.title' })}
        actions={
          <Button variant="primary" size="md" data-testid="tag-create-action" onClick={openCreate}>
            {intl.formatMessage({ id: 'entities.tag.list.createAction' })}
          </Button>
        }
      >
        <QueryStateBoundary
          state={
            (recordsQuery.isLoading
              ? 'loading'
              : recordsQuery.isError
                ? classifyError(recordsQuery.error)
                : 'success') as RendererState
          }
          onRetry={() => {
            void recordsQuery.refetch()
          }}
          columns={[{ widthPercent: 70 }, { widthPercent: 30 }]}
        >
          {recordsQuery.isError && (
            <p style={{ color: 'var(--color-error-dark)' }}>
              {intl.formatMessage({ id: 'entities.tag.list.loadError' })}
            </p>
          )}

          <DataTable<EntityRecord>
            columns={columns}
            data={rows}
            emptyMessage={intl.formatMessage({ id: 'entities.tag.list.emptyMessage' })}
          />

          <div style={{ marginTop: '.85rem' }}>
            <PaginationControls
              page={page}
              pageSize={PAGE_SIZE}
              totalItems={null}
              hasNextPage={hasNextPage}
              onPageChange={(nextPage) => (nextPage > page ? goNext() : goPrev())}
            />
          </div>
        </QueryStateBoundary>

        {modal && definition && (
          <div
            data-testid="tag-form-modal"
            role="dialog"
            aria-modal="true"
            style={{
              position: 'fixed',
              inset: 0,
              background: 'var(--surface-overlay)',
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              zIndex: 40,
            }}
          >
            <div style={{ background: 'var(--surface-card)', borderRadius: '8px', padding: '1.5rem', width: '90vw', maxWidth: '480px' }}>
              <h3 style={{ marginTop: 0 }}>
                {intl.formatMessage({ id: modal.kind === 'create' ? 'entities.tag.form.createTitle' : 'entities.tag.form.editTitle' })}
              </h3>
              <EntityRecordForm
                definition={definition}
                fieldTitles={{ name: intl.formatMessage({ id: 'entities.tag.field.name' }) }}
                initialValues={modal.kind === 'edit' ? modal.record.field_values : undefined}
                onSubmit={(values) => handleSubmit(values)}
                onCancel={closeModal}
                isSubmitting={createMutation.isPending || updateMutation.isPending}
                apiError={formError}
                submitLabel={intl.formatMessage({
                  id: modal.kind === 'create' ? 'entities.tag.form.submitCreate' : 'entities.tag.form.submitUpdate',
                })}
                cancelLabel={intl.formatMessage({ id: 'entities.tag.form.cancel' })}
              />
            </div>
          </div>
        )}

        {deleteError && <p style={{ color: 'var(--color-error-dark)' }}>{deleteError}</p>}

        <ConfirmDialog
          open={deleteTarget != null}
          title={intl.formatMessage({ id: 'entities.tag.delete.confirmTitle' })}
          body={intl.formatMessage({ id: 'entities.tag.delete.confirmBody' })}
          confirmText={intl.formatMessage({ id: 'entities.tag.delete.confirmAction' })}
          cancelText={intl.formatMessage({ id: 'entities.tag.delete.cancelAction' })}
          confirmVariant="danger"
          isLoading={deleteMutation.isPending}
          onConfirm={confirmDelete}
          onCancel={() => setDeleteTarget(null)}
        />
      </PageLayout>
    </div>
  )
}

export default function TagListPage() {
  return (
    <EntitiesIntlProvider>
      <TagListPageInner />
    </EntitiesIntlProvider>
  )
}
