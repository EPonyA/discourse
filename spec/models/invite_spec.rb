# frozen_string_literal: true

require 'rails_helper'

describe Invite do

  it { is_expected.to validate_presence_of :invited_by_id }

  it { is_expected.to rate_limit }

  let(:iceking) { 'iceking@adventuretime.ooo' }

  context 'user validators' do
    fab!(:coding_horror) { Fabricate(:coding_horror) }
    fab!(:user) { Fabricate(:user) }
    let(:invite) { Invite.create(email: user.email, invited_by: coding_horror) }

    it "should not allow an invite with the same email as an existing user" do
      expect(invite).not_to be_valid
    end

    it "should not allow a user to invite themselves" do
      expect(invite.email_already_exists).to eq(true)
    end
  end

  context 'email validators' do
    fab!(:coding_horror) { Fabricate(:coding_horror) }

    it "should not allow an invite with unformatted email address" do
      invite = Fabricate.build(:invite, email: "John Doe <john.doe@example.com>")
      expect(invite.valid?).to eq(false)
      expect(invite.errors.details[:email].first[:error]).to eq(I18n.t("user.email.invalid"))
    end

    it "should not allow an invite with blocklisted email" do
      invite = Invite.create(email: "test@mailinator.com", invited_by: coding_horror)
      expect(invite).not_to be_valid
    end

    it "should allow an invite with non-blocklisted email" do
      invite = Fabricate(:invite, email: "test@mail.com", invited_by: coding_horror)
      expect(invite).to be_valid
    end

    it "should not allow an invalid email address" do
      invite = Fabricate.build(:invite, email: 'asjdso')
      expect(invite.valid?).to eq(false)
      expect(invite.errors.details[:email].first[:error]).to eq(I18n.t("user.email.invalid"))
    end
  end

  context "DiscourseConnect validation" do
    it "prevents creating an email invite when DiscourseConnect is enabled" do
      SiteSetting.discourse_connect_url = "https://www.example.com/sso"
      SiteSetting.enable_discourse_connect = true

      invite = Fabricate.build(:invite, email: "test@mail.com")
      expect(invite).not_to be_valid
      expect(invite.errors.details[:email].first[:error]).to eq(I18n.t("invite.disabled_errors.discourse_connect_enabled"))
    end
  end

  context '#create' do
    context 'saved' do
      subject { Fabricate(:invite) }

      it "works" do
        expect(subject.invite_key).to be_present
        expect(subject.email_already_exists).to eq(false)
      end

      it 'should store a lower case version of the email' do
        expect(subject.email).to eq(iceking)
      end
    end

    context 'to a topic' do
      fab!(:topic) { Fabricate(:topic) }
      let(:inviter) { topic.user }

      context 'email' do
        it 'enqueues a job to email the invite' do
          expect do
            Invite.generate(inviter, email: iceking, topic: topic)
          end.to change { Jobs::InviteEmail.jobs.size }
        end
      end

      context 'links' do
        it 'does not enqueue a job to email the invite' do
          expect { Invite.generate(inviter, email: iceking, topic: topic, skip_email: true) }
            .not_to change { Jobs::InviteEmail.jobs.size }
        end
      end

      context 'destroyed' do
        it "can invite the same user after their invite was destroyed" do
          Invite.generate(inviter, email: iceking, topic: topic).destroy!
          invite = Invite.generate(inviter, email: iceking, topic: topic)
          expect(invite).to be_present
        end
      end

      context 'after created' do
        let(:invite) { Invite.generate(inviter, email: iceking, topic: topic) }

        it 'belongs to the topic' do
          expect(topic.invites).to eq([invite])
          expect(invite.topics).to eq([topic])
        end

        context 'when added by another user' do
          fab!(:coding_horror) { Fabricate(:coding_horror) }

          let(:new_invite) do
            Invite.generate(coding_horror, email: iceking, topic: topic)
          end

          it 'returns a different invite' do
            expect(new_invite).not_to eq(invite)
            expect(new_invite.invite_key).not_to eq(invite.invite_key)
            expect(new_invite.topics).to eq([topic])
          end
        end

        context 'when adding a duplicate' do
          it 'returns the original invite' do
            %w{
              iceking@adventuretime.ooo
              iceking@ADVENTURETIME.ooo
              ICEKING@adventuretime.ooo
            }.each do |email|
              expect(Invite.generate(inviter, email: email, topic: topic)).to eq(invite)
            end
          end

          it 'updates timestamp of existing invite' do
            freeze_time
            invite.update!(created_at: 10.days.ago)

            resend_invite = Invite.generate(inviter, email: 'iceking@adventuretime.ooo', topic: topic)

            expect(resend_invite.created_at).to eq_time(Time.zone.now)
          end

          it 'returns a new invite if the other has expired' do
            SiteSetting.invite_expiry_days = 1
            invite.update!(expires_at: 2.days.ago)

            new_invite = Invite.generate(inviter, email: 'iceking@adventuretime.ooo', topic: topic)
            expect(new_invite).not_to eq(invite)
            expect(new_invite).not_to be_expired
          end
        end

        context 'when adding to another topic' do
          fab!(:another_topic) { Fabricate(:topic, user: topic.user) }

          it 'should be the same invite' do
            new_invite = Invite.generate(inviter, email: iceking, topic: another_topic)
            expect(new_invite).to eq(invite)
            expect(another_topic.invites).to eq([invite])
            expect(invite.topics).to match_array([topic, another_topic])
          end
        end

        it 'resets expiry of a resent invite' do
          SiteSetting.invite_expiry_days = 2
          invite.update!(invalidated_at: 10.days.ago, expires_at: 10.days.ago)
          expect(invite).to be_expired

          invite.resend_invite
          expect(invite.invalidated_at).to be_nil
          expect(invite).not_to be_expired
        end

        it 'correctly marks invite emailed_status for email invites' do
          expect(invite.emailed_status).to eq(Invite.emailed_status_types[:sending])

          Invite.generate(inviter, email: iceking, topic: topic)
          expect(invite.reload.emailed_status).to eq(Invite.emailed_status_types[:sending])
        end

        it 'does not mark emailed_status as sending after generating invite link' do
          expect(invite.emailed_status).to eq(Invite.emailed_status_types[:sending])

          Invite.generate(inviter, email: iceking, topic: topic, emailed_status: Invite.emailed_status_types[:not_required])
          expect(invite.reload.emailed_status).to eq(Invite.emailed_status_types[:not_required])

          Invite.generate(inviter, email: iceking, topic: topic)
          expect(invite.reload.emailed_status).to eq(Invite.emailed_status_types[:not_required])

          Invite.generate(inviter, email: iceking, topic: topic, emailed_status: Invite.emailed_status_types[:not_required])
          expect(invite.reload.emailed_status).to eq(Invite.emailed_status_types[:not_required])
        end
      end
    end

    context 'invite links' do
      let(:inviter) { Fabricate(:user) }

      it "can be created" do
        invite = Invite.generate(inviter, max_redemptions_allowed: 5)
        expect(invite.max_redemptions_allowed).to eq(5)
        expect(invite.expires_at.to_date).to eq(SiteSetting.invite_expiry_days.days.from_now.to_date)
        expect(invite.emailed_status).to eq(Invite.emailed_status_types[:not_required])
        expect(invite.is_invite_link?).to eq(true)
      end

      it 'checks for max_redemptions_allowed range' do
        SiteSetting.invite_link_max_redemptions_limit = 1000
        expect { Invite.generate(inviter, max_redemptions_allowed: 1001) }
          .to raise_error(ActiveRecord::RecordInvalid)
      end

      it 'does not enqueue a job to email the invite' do
        expect { Invite.generate(inviter) }
          .not_to change { Jobs::InviteEmail.jobs.size }
      end
    end
  end

  context 'an existing user' do
    fab!(:topic) { Fabricate(:topic, category_id: nil, archetype: 'private_message') }
    fab!(:coding_horror) { Fabricate(:coding_horror) }

    it "works" do
      expect { Invite.generate(topic.user, email: coding_horror.email, topic: topic) }
        .to raise_error(Invite::UserExists)
    end
  end

  context 'a staged user' do
    it 'creates an invite for a staged user' do
      Fabricate(:staged, email: 'staged@account.com')
      invite = Invite.generate(Fabricate(:coding_horror), email: 'staged@account.com')

      expect(invite).to be_valid
      expect(invite.email).to eq('staged@account.com')
    end
  end

  context '.redeem' do

    fab!(:invite) { Fabricate(:invite) }

    it 'creates a notification for the invitee' do
      expect { invite.redeem }.to change(Notification, :count)
    end

    it 'wont redeem an expired invite' do
      SiteSetting.invite_expiry_days = 10
      invite.update_column(:expires_at, 20.days.ago)
      expect(invite.redeem).to be_blank
    end

    it 'wont redeem a deleted invite' do
      invite.destroy
      expect(invite.redeem).to be_blank
    end

    it "won't redeem an invalidated invite" do
      invite.invalidated_at = 1.day.ago
      expect(invite.redeem).to be_blank
    end

    context "deletes duplicate invites" do
      fab!(:another_user) { Fabricate(:user) }

      it 'delete duplicate invite' do
        another_invite = Fabricate(:invite, email: invite.email, invited_by: another_user)
        invite.redeem
        duplicate_invite = Invite.find_by(id: another_invite.id)
        expect(duplicate_invite).to be_nil
      end

      it 'does not delete already redeemed invite' do
        redeemed_invite = Fabricate(:invite, email: invite.email, invited_by: another_user)
        Fabricate(:invited_user, invite: invite, user: Fabricate(:user))
        invite.redeem
        used_invite = Invite.find_by(id: redeemed_invite.id)
        expect(used_invite).not_to be_nil
      end
    end

    context "as a moderator" do
      it "will give the user a moderator flag" do
        invite.invited_by = Fabricate(:admin)
        invite.moderator = true
        invite.save

        user = invite.redeem
        expect(user).to be_moderator
      end

      it "will not give the user a moderator flag if the inviter is not staff" do
        invite.moderator = true
        invite.save

        user = invite.redeem
        expect(user).not_to be_moderator
      end
    end

    context "when inviting to groups" do
      it "add the user to the correct groups" do
        group = Fabricate(:group)
        group.add_owner(invite.invited_by)
        invite.invited_groups.build(group_id: group.id)
        invite.save

        user = invite.redeem
        expect(user.groups.count).to eq(1)
      end
    end

    context "invite trust levels" do
      it "returns the trust level in default_invitee_trust_level" do
        SiteSetting.default_invitee_trust_level = TrustLevel[3]
        expect(invite.redeem.trust_level).to eq(TrustLevel[3])
      end
    end

    context 'inviting when must_approve_users? is enabled' do
      it 'correctly activates accounts' do
        invite.invited_by = Fabricate(:admin)
        SiteSetting.must_approve_users = true
        user = invite.redeem
        expect(user.approved?).to eq(true)
      end
    end

    context 'simple invite' do
      let!(:user) { invite.redeem }

      it 'works correctly' do
        expect(user.is_a?(User)).to eq(true)
        expect(user.send_welcome_message).to eq(true)
        expect(user.trust_level).to eq(SiteSetting.default_invitee_trust_level)
      end

      context 'after redeeming' do
        before do
          invite.reload
        end

        it 'works correctly' do
          # has set the user_id attribute
          expect(invite.invited_users.first.user).to eq(user)

          # returns true for redeemed
          expect(invite).to be_redeemed
        end

        context 'again' do
          it 'will not redeem twice' do
            expect(invite.redeem).to be_blank
          end
        end
      end
    end

    context 'invited to topics' do
      fab!(:tl2_user) { Fabricate(:user, trust_level: 2) }
      fab!(:topic) { Fabricate(:private_message_topic, user: tl2_user) }

      let!(:invite) do
        topic.invite(topic.user, 'jake@adventuretime.ooo')
        Invite.find_by(invited_by_id: topic.user)
      end

      context 'redeem topic invite' do
        it 'adds the user to the topic_users' do
          user = invite.redeem
          topic.reload
          expect(topic.allowed_users.include?(user)).to eq(true)
          expect(Guardian.new(user).can_see?(topic)).to eq(true)
        end
      end

      context 'invited by another user to the same topic' do
        fab!(:another_tl2_user) { Fabricate(:user, trust_level: 2) }
        let!(:another_invite) { topic.invite(another_tl2_user, 'jake@adventuretime.ooo') }
        let!(:user) { invite.redeem }

        it 'adds the user to the topic_users' do
          topic.reload
          expect(topic.allowed_users.include?(user)).to eq(true)
        end
      end

      context 'invited by another user to a different topic' do
        let!(:user) { invite.redeem }
        fab!(:another_tl2_user) { Fabricate(:user, trust_level: 2) }
        fab!(:another_topic) { Fabricate(:topic, user: another_tl2_user) }

        it 'adds the user to the topic_users of the first topic' do
          expect(another_topic.invite(another_tl2_user, user.username)).to be_truthy # invited via username
          expect(topic.allowed_users.include?(user)).to eq(true)
        end
      end
    end

    context 'invite_link' do
      fab!(:invite_link) { Fabricate(:invite, email: nil, max_redemptions_allowed: 5, expires_at: 1.month.from_now, emailed_status: Invite.emailed_status_types[:not_required]) }

      it 'works correctly' do
        user = invite_link.redeem(email: 'foo@example.com')
        expect(user.is_a?(User)).to eq(true)
        expect(user.send_welcome_message).to eq(true)
        expect(user.trust_level).to eq(SiteSetting.default_invitee_trust_level)
        expect(user.active).to eq(false)
        expect(invite_link.reload.redemption_count).to eq(1)
      end

      it 'returns error if user with that email already exists' do
        user = Fabricate(:user)
        expect { invite_link.redeem(email: user.email) }.to raise_error(Invite::UserExists)
      end
    end
  end

  describe '.pending' do
    context 'with user that has invited' do
      it 'returns invites' do
        inviter = Fabricate(:user)
        invite = Fabricate(:invite, invited_by: inviter)

        expect(Invite.pending(inviter)).to include(invite)
      end
    end

    context 'with user that has not invited' do
      it 'does not return invites' do
        user = Fabricate(:user)
        Fabricate(:invite)

        expect(Invite.pending(user)).to be_empty
      end
    end

    it 'returns pending invites only' do
      inviter = Fabricate(:user)

      redeemed_invite = Fabricate(:invite, invited_by: inviter, email: 'redeemed@example.com')
      redeemed_invite.redeem

      pending_invite = Fabricate(:invite, invited_by: inviter, email: 'pending@example.com')
      pending_link_invite = Fabricate(:invite, invited_by: inviter, max_redemptions_allowed: 5)

      expect(Invite.pending(inviter)).to contain_exactly(pending_invite, pending_link_invite)
    end
  end

  describe '.redeemed' do
    it 'returns redeemed invites only' do
      inviter = Fabricate(:user)

      Fabricate(:invite, invited_by: inviter, email: 'pending@example.com')

      redeemed_invite = Fabricate(:invite, invited_by: inviter, email: 'redeemed@example.com')
      Fabricate(:invited_user, invite: redeemed_invite, user: Fabricate(:user))

      expect(Invite.redeemed_users(inviter)).to contain_exactly(redeemed_invite.invited_users.first)
    end

    it 'returns redeemed invites for invite links' do
      inviter = Fabricate(:user)
      invite_link = Fabricate(:invite, invited_by: inviter, max_redemptions_allowed: 50)

      redeemed = [
        Fabricate(:invited_user, invite: invite_link, user: Fabricate(:user)),
        Fabricate(:invited_user, invite: invite_link, user: Fabricate(:user)),
        Fabricate(:invited_user, invite: invite_link, user: Fabricate(:user))
      ]

      expect(Invite.redeemed_users(inviter)).to match_array(redeemed)
    end
  end

  describe '.invalidate_for_email' do
    let(:email) { 'invite.me@example.com' }
    subject { described_class.invalidate_for_email(email) }

    it 'returns nil if there is no invite for the given email' do
      expect(subject).to eq(nil)
    end

    it 'sets the matching invite to be invalid' do
      invite = Fabricate(:invite, invited_by: Fabricate(:user), email: email)
      expect(subject).to eq(invite)
      expect(subject.link_valid?).to eq(false)
      expect(subject).to be_valid
    end

    it 'sets the matching invite to be invalid without being case-sensitive' do
      invite = Fabricate(:invite, invited_by: Fabricate(:user), email: 'invite.me2@Example.COM')
      result = described_class.invalidate_for_email('invite.me2@EXAMPLE.com')
      expect(result).to eq(invite)
      expect(result.link_valid?).to eq(false)
      expect(result).to be_valid
    end
  end

  describe '.redeem_from_email' do
    fab!(:inviter) { Fabricate(:user) }
    fab!(:invite) { Fabricate(:invite, invited_by: inviter, email: 'test@example.com') }
    fab!(:user) { Fabricate(:user, email: invite.email) }

    it 'redeems the invite from email' do
      Invite.redeem_from_email(user.email)
      invite.reload
      expect(invite).to be_redeemed
    end

    it 'does not redeem the invite if email does not match' do
      Invite.redeem_from_email('test24@example.com')
      invite.reload
      expect(invite).not_to be_redeemed
    end
  end

  describe '#emailed_status_types' do
    context "verify enum sequence" do
      before do
        @emailed_status_types = Invite.emailed_status_types
      end

      it "'not_required' should be at 0 position" do
        expect(@emailed_status_types[:not_required]).to eq(0)
      end

      it "'sent' should be at 4th position" do
        expect(@emailed_status_types[:sent]).to eq(4)
      end
    end
  end
end
