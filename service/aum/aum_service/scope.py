from dataclasses import dataclass

from .errors import AccessDenied


@dataclass(frozen=True)
class ManagerScope:
    organization_ids: frozenset[str]
    department_ids: frozenset[str]
    context_organization_ids: frozenset[str]
    writable_department_ids: frozenset[str]
    entities: tuple[dict, ...]

    def contains_leaf(self, leaf):
        return leaf in self.organization_ids or leaf in self.department_ids

    def require_read(self, scope_type, scope_id, person_leaf=None):
        if scope_type == "organization" and scope_id in self.organization_ids:
            return
        if scope_type == "department" and scope_id in self.department_ids:
            return
        if scope_type == "user" and self.contains_leaf(person_leaf):
            return
        raise AccessDenied()

    def require_write(self, scope_type, scope_id, person_leaf=None):
        if scope_type == "department" and scope_id in self.writable_department_ids:
            return
        if scope_type == "user" and self.contains_leaf(person_leaf):
            return
        raise AccessDenied("Budget is outside your writable scope")

    def profile(self):
        return {
            "organizations": [e for e in self.entities if e["id"] in self.organization_ids],
            "departments": [e for e in self.entities if e["id"] in self.department_ids],
            "writable_department_ids": sorted(self.writable_department_ids),
        }

    def catalog(self):
        return [e for e in self.entities if e["id"] in (
            self.context_organization_ids | self.department_ids
        )]


def resolve_scope(groups, entities, mappings):
    if groups is None:
        return None
    held = set(groups)

    def managed(entity):
        group = mappings.get(entity["id"])
        return isinstance(group, str) and group.lower() in held

    organizations = frozenset(e["id"] for e in entities if not e.get("parent_id") and managed(e))
    departments = frozenset(e["id"] for e in entities if e.get("parent_id") and (
        managed(e) or e["parent_id"] in organizations
    ))
    context = organizations | frozenset(e["parent_id"] for e in entities if e["id"] in departments)
    writable = frozenset(e["id"] for e in entities if e.get("parent_id") in organizations)
    return ManagerScope(organizations, departments, context, writable, tuple(entities))
