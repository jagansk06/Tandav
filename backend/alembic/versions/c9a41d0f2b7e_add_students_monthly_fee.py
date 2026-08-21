"""add students.monthly_fee

Revision ID: c9a41d0f2b7e
Revises: 25c0848eef5b
Create Date: 2026-08-10 10:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'c9a41d0f2b7e'
down_revision: Union[str, None] = '25c0848eef5b'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        'students',
        sa.Column('monthly_fee', sa.Numeric(precision=12, scale=2),
                  server_default=sa.text('0'), nullable=False),
    )


def downgrade() -> None:
    op.drop_column('students', 'monthly_fee')
