<script lang="ts">
  import { createQuery, getClient } from "@hcengineering/presentation"
  import { type Group } from "@hcengineering/group"
  import groupPlugin from "@hcengineering/group"
  import { showPopup, Header, Breadcrumb, Scroller, ModernButton, IconAdd } from "@hcengineering/ui"
  import { AccountArrayEditor } from "@hcengineering/contact-resources"
  import CreateGroup from "./CreateGroup.svelte"

  let groups: Group[] = []
  let loading = true

  const groupQuery = createQuery()

  groupQuery.query(groupPlugin.class.Group, {}, (res: Group[]) => {
    groups = res
    loading = false
  })

  function handleCreate (): void {
    showPopup(CreateGroup, {}, "top")
  }

  function handleEdit (group: Group): void {
    showPopup(CreateGroup, { group }, "top")
  }
</script>

<div class="hulyComponent">
  <Header adaptive={"disabled"}>
    <Breadcrumb icon={groupPlugin.icon.Group} label={groupPlugin.string.Groups} size={"large"} isCurrent />
    <svelte:fragment slot="actions">
      <ModernButton kind="primary" icon={IconAdd} label={groupPlugin.string.CreateGroup} size="small" on:click={handleCreate} />
    </svelte:fragment>
  </Header>
  <div class="hulyComponent-content__column content">
    {#if loading}
      <div class="w-full h-full flex-col-center justify-center">
        <div class="flex-col-center"><p class="p-2">Loading groups...</p></div>
      </div>
    {:else if groups.length === 0}
      <div class="flex-col-center mt-8">
        <p>No groups created yet.</p>
      </div>
    {:else}
      <Scroller align={"center"} padding={"var(--spacing-3)"} bottomPadding={"var(--spacing-3)"}>
        <div class="hulyComponent-content">
          {#each groups as group}
            <div class="antiGrid-row">
              <div class="antiGrid-row__header">
                {group.name}
              </div>
              <div class="members-pill" style="display:inline-flex; align-items:center;">
                <AccountArrayEditor
                  value={group.members}
                  label={groupPlugin.string.GroupMembers}
                  onChange={(newMembers) => {
                    const client = getClient()
                    void client.update(group, { members: newMembers })
                  }}
                  kind="regular"
                  size="large"
                />
              </div>
              <button class="edit-pencil" on:click={() => handleEdit(group)} title="Edit group">
                <svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor">
                  <path d="M11.5 1.5C11.6326 1.5 11.7598 1.55268 11.8536 1.64645L14.3536 4.14645C14.4473 4.24022 14.5 4.36739 14.5 4.5C14.5 4.63261 14.4473 4.75979 14.3536 4.85355L5.85355 13.3536C5.75979 13.4473 5.63261 13.5 5.5 13.5H3C2.72386 13.5 2.5 13.2761 2.5 13V10.5C2.5 10.3674 2.55268 10.2402 2.64645 10.1464L10.1464 2.64645C10.2402 2.55268 10.3674 2.5 10.5 2.5H11.5ZM10.5 3.60355L3.5 10.6036V12.5H5.39645L12.3964 5.5L10.5 3.60355ZM13.5 4.5L11.5 2.5L12.6464 3.64645L13.5 4.5Z" />
                </svg>
              </button>
            </div>
          {/each}
        </div>
      </Scroller>
    {/if}
  </div>
</div>

<style lang="scss">
  .antiGrid-row {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.25rem 0;
  }
  .antiGrid-row__header {
    flex-shrink: 0;
    width: 12rem;
    font-size: 0.875rem;
    font-weight: 400;
    color: var(--theme-caption-color);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .edit-pencil {
    background: none;
    border: none;
    cursor: pointer;
    padding: 0.25rem;
    color: var(--theme-caption-color);
    display: inline-flex;
    align-items: center;
    &:hover { color: var(--theme-accent-color); }
  }
</style>